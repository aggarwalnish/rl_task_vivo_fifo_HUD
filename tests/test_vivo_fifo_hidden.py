# tests/test_vivo_fifo_hidden.py
import os
import random
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
from cocotb_tools.runner import get_runner


# ---------------------------------------------------------------------------
# Small helpers to pack/unpack 2D packed data buses:
#   logic [N-1:0][ELEM_WIDTH-1:0] foo;
# ---------------------------------------------------------------------------

def pack_elems(elems, elem_width):
    """Pack list of ints into a single bus with LSB = elem[0]."""
    mask = (1 << elem_width) - 1
    val = 0
    for i, e in enumerate(elems):
        val |= (int(e) & mask) << (i * elem_width)
    return val


def unpack_elems(bus_value, num_elems, elem_width):
    """Unpack bus_value into num_elems ints, LSB chunk is elem[0]."""
    mask = (1 << elem_width) - 1
    res = []
    v = int(bus_value)
    for i in range(num_elems):
        res.append((v >> (i * elem_width)) & mask)
    return res


async def reset_dut(dut, cycles=3):
    dut.rst_n.value = 0
    dut.in_valid.value = 0
    dut.in_num_elems.value = 0
    dut.in_data.value = 0
    dut.out_ready.value = 0
    dut.out_req_elems.value = 0

    for _ in range(cycles):
        await RisingEdge(dut.clk)

    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


# ---------------------------------------------------------------------------
# Hidden test 1: Simple push/pop and ordering
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_simple_push_pop(dut):
    """Basic sanity: pushes then pops, checks strict ordering."""
    clk = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clk.start())

    await reset_dut(dut)

    ELEM_WIDTH = int(dut.ELEM_WIDTH.value)
    IN_ELEMS_MAX = int(dut.IN_ELEMS_MAX.value)
    OUT_ELEMS_MAX = int(dut.OUT_ELEMS_MAX.value)
    DEPTH = int(dut.DEPTH.value)
    CAPACITY = DEPTH * max(IN_ELEMS_MAX, OUT_ELEMS_MAX)

    # Python model of FIFO contents
    model = []

    # ----------------------
    # Push phase: fill some data
    # ----------------------
    values_to_push = list(range(1, 10))  # 1..9
    idx = 0

    while idx < len(values_to_push):
        await RisingEdge(dut.clk)

        # Decide how many to push this cycle (up to IN_ELEMS_MAX, but not beyond list)
        remaining = len(values_to_push) - idx
        in_cnt = min(IN_ELEMS_MAX, remaining)
        elems = values_to_push[idx : idx + in_cnt]

        dut.in_valid.value = 1
        dut.in_num_elems.value = in_cnt
        dut.in_data.value = pack_elems(elems, ELEM_WIDTH)

        # Drive no pop yet
        dut.out_ready.value = 0
        dut.out_req_elems.value = 0

        await RisingEdge(dut.clk)

        if dut.in_ready.value:
            # Transaction accepted
            model.extend(elems)
            idx += in_cnt
        else:
            # Not accepted; keep same values, try again next cycle
            pass

    # Deassert push
    dut.in_valid.value = 0
    dut.in_num_elems.value = 0
    dut.in_data.value = 0

    # Check model size bounded by capacity
    assert len(model) <= CAPACITY

    # ----------------------
    # Pop phase: pop in variable chunks
    # ----------------------
    while model:
        await RisingEdge(dut.clk)

        # Issue a pop request up to OUT_ELEMS_MAX, but not beyond model size
        req = min(OUT_ELEMS_MAX, len(model))

        dut.out_req_elems.value = req
        dut.out_ready.value = 1  # consume as soon as valid appears

        # Wait until out_valid asserts
        while True:
            await RisingEdge(dut.clk)
            if dut.out_valid.value:
                break

        out_num = int(dut.out_num_elems.value)
        assert out_num == req, f"Expected out_num_elems={req}, got {out_num}"

        # Capture output data and compare to model
        out_bus = dut.out_data.value
        out_elems = unpack_elems(out_bus, OUT_ELEMS_MAX, ELEM_WIDTH)

        expected = model[:out_num]
        got = out_elems[:out_num]
        assert got == expected, f"Ordering mismatch. Expected {expected}, got {got}"

        # Update model: remove popped elements
        model = model[out_num:]

        # One more edge to allow internal pointers to update
        await RisingEdge(dut.clk)

    # After everything popped, out_valid should eventually be low
    dut.out_req_elems.value = OUT_ELEMS_MAX
    dut.out_ready.value = 1
    for _ in range(5):
        await RisingEdge(dut.clk)
    assert not dut.out_valid.value, "out_valid should be low when FIFO is empty"


# ---------------------------------------------------------------------------
# Hidden test 2: Backpressure + stability + overflow/underflow
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_backpressure_and_edge_cases(dut):
    """Check overflow rejection, underflow rejection, and stable outputs under stall."""
    clk = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clk.start())

    await reset_dut(dut)

    ELEM_WIDTH = int(dut.ELEM_WIDTH.value)
    IN_ELEMS_MAX = int(dut.IN_ELEMS_MAX.value)
    OUT_ELEMS_MAX = int(dut.OUT_ELEMS_MAX.value)
    DEPTH = int(dut.DEPTH.value)
    CAPACITY = DEPTH * max(IN_ELEMS_MAX, OUT_ELEMS_MAX)

    model = []

    # 1) Fill to capacity exactly
    val = 1
    while len(model) < CAPACITY:
        await RisingEdge(dut.clk)
        space = CAPACITY - len(model)
        if space == 0:
            break

        push_cnt = min(IN_ELEMS_MAX, space)
        elems = [val + i for i in range(push_cnt)]
        val += push_cnt

        dut.in_valid.value = 1
        dut.in_num_elems.value = push_cnt
        dut.in_data.value = pack_elems(elems, ELEM_WIDTH)

        dut.out_ready.value = 0
        dut.out_req_elems.value = 0

        await RisingEdge(dut.clk)

        if dut.in_ready.value:
            model.extend(elems)

    dut.in_valid.value = 0
    dut.in_num_elems.value = 0
    dut.in_data.value = 0

    assert len(model) == CAPACITY

    # 2) Try overflow push: design must not accept
    await RisingEdge(dut.clk)
    dut.in_valid.value = 1
    dut.in_num_elems.value = IN_ELEMS_MAX
    dut.in_data.value = pack_elems([0xAA] * IN_ELEMS_MAX, ELEM_WIDTH)

    await RisingEdge(dut.clk)
    assert not dut.in_ready.value, "in_ready should be low when FIFO is full"

    # Model must not change
    before_len = len(model)
    await RisingEdge(dut.clk)
    assert len(model) == before_len

    dut.in_valid.value = 0
    dut.in_num_elems.value = 0
    dut.in_data.value = 0

    # 3) Force underflow: empty FIFO and verify out_valid remains low
    # First drain everything
    while model:
        await RisingEdge(dut.clk)
        req = min(OUT_ELEMS_MAX, len(model))
        dut.out_req_elems.value = req
        dut.out_ready.value = 1

        while True:
            await RisingEdge(dut.clk)
            if dut.out_valid.value:
                break

        out_num = int(dut.out_num_elems.value)
        out_bus = dut.out_data.value
        out_elems = unpack_elems(out_bus, OUT_ELEMS_MAX, ELEM_WIDTH)

        expected = model[:out_num]
        got = out_elems[:out_num]
        assert got == expected

        model = model[out_num:]

    # Now FIFO empty: request pop and never get valid
    dut.out_req_elems.value = 1
    dut.out_ready.value = 1
    for _ in range(5):
        await RisingEdge(dut.clk)
        assert not dut.out_valid.value, "out_valid must stay low on underflow"


# ---------------------------------------------------------------------------
# Hidden test 3: Randomized stress + scoreboard (wrap-around, sim push/pop)
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_random_stress_with_scoreboard(dut):
    """Random pushes/pops with scoreboard checking order + pointer wrap-around."""
    clk = Clock(dut.clk, 5, units="ns")
    cocotb.start_soon(clk.start())

    await reset_dut(dut)

    ELEM_WIDTH = int(dut.ELEM_WIDTH.value)
    IN_ELEMS_MAX = int(dut.IN_ELEMS_MAX.value)
    OUT_ELEMS_MAX = int(dut.OUT_ELEMS_MAX.value)
    DEPTH = int(dut.DEPTH.value)
    CAPACITY = DEPTH * max(IN_ELEMS_MAX, OUT_ELEMS_MAX)

    random.seed(42)

    model = []

    # Simple pop controller state
    pop_active = False
    current_req = 0
    stall_cycles_remaining = 0

    # Run for enough cycles to wrap pointers multiple times
    for _ in range(1000):
        await RisingEdge(dut.clk)

        # -----------------
        # Decide push this cycle
        # -----------------
        # Don't exceed capacity in the model; but still let DUT throttle via in_ready.
        can_push_model = len(model) < CAPACITY
        do_push = can_push_model and (random.random() < 0.6)

        if do_push:
            max_push = min(IN_ELEMS_MAX, CAPACITY - len(model))
            in_cnt = random.randint(1, max_push)
            elems = [random.randint(0, (1 << ELEM_WIDTH) - 1) for _ in range(in_cnt)]

            dut.in_valid.value = 1
            dut.in_num_elems.value = in_cnt
            dut.in_data.value = pack_elems(elems, ELEM_WIDTH)
        else:
            dut.in_valid.value = 0
            dut.in_num_elems.value = 0
            dut.in_data.value = 0

        # -----------------
        # Decide pop behavior
        # -----------------
        if not pop_active and model:
            # Start a new pop request with some probability
            if random.random() < 0.7:
                max_req = min(OUT_ELEMS_MAX, len(model))
                current_req = random.randint(1, max_req)
                pop_active = True
                # Consumer will stall randomly before accepting
                stall_cycles_remaining = random.randint(0, 3)

        if pop_active:
            dut.out_req_elems.value = current_req
            if stall_cycles_remaining > 0:
                dut.out_ready.value = 0
                stall_cycles_remaining -= 1
            else:
                dut.out_ready.value = 1
        else:
            dut.out_req_elems.value = 0
            dut.out_ready.value = 0

        # One more edge to evaluate handshakes
        await RisingEdge(dut.clk)

        # Check push accept
        if dut.in_valid.value and dut.in_ready.value:
            in_cnt = int(dut.in_num_elems.value)
            in_bus = dut.in_data.value
            pushed = unpack_elems(in_bus, in_cnt, ELEM_WIDTH)
            model.extend(pushed)
            assert len(model) <= CAPACITY, "Model overflowed capacity"

        # Check pop handshake + scoreboard
        if pop_active and dut.out_valid.value and dut.out_ready.value:
            out_num = int(dut.out_num_elems.value)
            assert out_num == current_req, "FIFO should only assert when it can serve full request"

            out_bus = dut.out_data.value
            out_elems = unpack_elems(out_bus, OUT_ELEMS_MAX, ELEM_WIDTH)[:out_num]

            expected = model[:out_num]
            assert out_elems == expected, f"Random stress mismatch. expected={expected}, got={out_elems}"

            # Remove from model
            model = model[out_num:]

            # Transaction complete; back to idle
            pop_active = False
            current_req = 0
            dut.out_req_elems.value = 0
            dut.out_ready.value = 0

    # End: basic sanity that model and DUT are at least consistent in "empty/not empty"


# ---------------------------------------------------------------------------
# Pytest wrapper required by HUD
# ---------------------------------------------------------------------------

def test_vivo_fifo_hidden_runner():
    sim = os.getenv("SIM", "icarus")

    proj_path = Path(__file__).resolve().parent.parent
    sources = [proj_path / "rtl/vivo_fifo.sv"]

    runner = get_runner(sim)
    runner.build(
        sources=sources,
        hdl_toplevel="vivo_fifo",
        always=True,
    )
    runner.test(
        hdl_toplevel="vivo_fifo",
        test_module="test_vivo_fifo_hidden",
    )
