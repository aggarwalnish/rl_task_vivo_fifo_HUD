# **Variable-Input / Variable-Output FIFO (VIVO FIFO) — Specifications**

## **1. Overview**

The **VIVO FIFO** is a hardware FIFO queue supporting:

* Variable number of input elements per push
* Variable number of output elements per pop
* Standard **valid/ready** handshake on both sides
* **Strict FIFO** ordering (element granularity)

The module is designed for:

* Packetization / depacketization paths
* Width conversion between producer & consumer

Behavior is **deterministic, synthesizable, and race-free**.

---

## **2. Parameters**

### **2.1 Top-Level VIVO FIFO (`vivo_fifo`)**

| Name            | Type         | Default | Description                                |
| --------------- | ------------ | ------- | ------------------------------------------ |
| `ELEM_WIDTH`    | int unsigned | 8       | Width of one element (bits)                |
| `IN_ELEMS_MAX`  | int unsigned | 4       | Max elements accepted per input transfer   |
| `OUT_ELEMS_MAX` | int unsigned | 4       | Max elements delivered per output transfer |
| `DEPTH`         | int unsigned | 128     | Maximum elements FIFO can store            |

For implementation convenience, many designs define:

```systemverilog
localparam int BANKS      = (IN_ELEMS_MAX >= OUT_ELEMS_MAX)
                            ? IN_ELEMS_MAX : OUT_ELEMS_MAX;
localparam int CAPACITY   = DEPTH;                    // total element capacity
localparam int BANK_DEPTH = (CAPACITY + BANKS - 1)
                            / BANKS;                  // entries per bank
```

The **architectural behavior** is always defined in terms of `DEPTH`
and `CAPACITY` (total elements), not how storage is physically organized.

### **2.2 Helper Synchronous FIFO (`sync_fifo`)**

The top-level implementation is expected to use a reusable synchronous FIFO
building block with this interface:

```systemverilog
module sync_fifo #(
    parameter int WIDTH = ELEM_WIDTH,
    parameter int DEPTH = BANK_DEPTH // entries per bank (chosen by top-level)
)(
    input  logic             clk,
    input  logic             rst_n,   // async active-low
    input  logic             wr_en,
    input  logic [WIDTH-1:0] wr_data,
    input  logic             rd_en,
    output logic [WIDTH-1:0] rd_data,
    output logic             empty,
    output logic             full
);
```

Requirements for `sync_fifo`:

- Single clock (`clk`), async active-low reset (`rst_n`).
- Strict FIFO ordering for `wr_data` elements.
- No internal overflow/underflow when driven correctly.
- Fully synthesizable (no dynamic constructs, latches, or DPI).

The exact internal structure (pointers, counters, RAM style) is up to you,
as long as it behaves as a conventional single-clock FIFO.

---

## **3. Top-Level Interface Specification**

All signals synchronous to `clk`. Reset is asynchronous active-low.

### **3.1 Clock + Reset**

| Signal  | Dir   | Width | Description                        |
| ------- | ----- | ----- | ---------------------------------- |
| `clk`   | Input | 1     | Rising-edge clock                  |
| `rst_n` | Input | 1     | Low = immediate asynchronous reset |

Reset effects defined in Section **6**.

---

### **3.2 Input (Producer) Interface**

| Signal         | Dir    | Width                        | Description                                            |
| -------------- | ------ | ---------------------------- | ------------------------------------------------------ |
| `in_valid`     | Input  | 1                            | Producer presenting new transfer                       |
| `in_ready`     | Output | 1                            | FIFO able to accept transfer                           |
| `in_data`      | Input  | `IN_ELEMS_MAX*ELEM_WIDTH`    | Packed elements, lane 0 oldest                         |
| `in_num_elems` | Input  | `ceil(log2(IN_ELEMS_MAX+1))` | Number of valid elements in transfer (1..IN_ELEMS_MAX) |

**Acceptance condition** (rising edge):
Transfer only pushed when:

```
in_valid == 1 && in_ready == 1
```

**Input ordering rule**:

| Lane | Contains              |
| ---- | --------------------- |
| 0    | Oldest among new push |
| 1    | Next oldest           |
| …    | …                     |

Unused lanes ≥ `in_num_elems` are **don’t care**.

---

### **3.3 Output (Consumer) Interface — Strict Request-Driven**

| Signal          | Dir    | Width                         | Description                          |
| --------------- | ------ | ----------------------------- | ------------------------------------ |
| `out_valid`     | Output | 1                             | FIFO presenting data for pop         |
| `out_ready`     | Input  | 1                             | Consumer accepting transfer          |
| `out_data`      | Output | `OUT_ELEMS_MAX*ELEM_WIDTH`    | Packed output elements               |
| `out_num_elems` | Output | `ceil(log2(OUT_ELEMS_MAX+1))` | = `out_req_elems` when valid         |
| `out_req_elems` | Input  | `ceil(log2(OUT_ELEMS_MAX+1))` | Required pop size (1..OUT_ELEMS_MAX) |

**Strict consumption requirement**:
Pop occurs **only when**:

```
out_valid == 1 && out_ready == 1
```

**No partial output**:

* If `occ < out_req_elems` → **no output**
* Lane validity: only lanes `0 .. out_req_elems-1` contain valid elements

**Output ordering rule**:

| Lane | Contains                      |
| ---- | ----------------------------- |
| 0    | Oldest element in entire FIFO |
| 1    | Next oldest                   |
| …    | …                             |

---

## **4. Internal Model**

FIFO stores sequence of elements:

```
queue[0] = oldest element stored
queue[N-1] = newest element stored
N = occ = occupancy
```

Always:

```
0 <= occ <= DEPTH
```

---

## **5. Functional Behavior**

### **5.1 Push (Input Accept) Rules**

Define:

```systemverilog
push_req   = (in_valid == 1);
push_elems = in_num_elems;
space      = DEPTH - occ;
```

**Conservative backpressure**:

```systemverilog
if (space >= push_elems)
    in_ready = 1;
else
    in_ready = 0;
```

Push occurs on rising edge if:

```systemverilog
push_fire = in_valid && in_ready;
```

On a successful push:

```systemverilog
occ_next = occ + push_elems;
```

New elements are always appended **after all existing elements**.

> Push **cannot** rely on pop to create space in same cycle.

---

### **5.2 Pop (Output Production) Rules**

Define:

```systemverilog
pop_req_elems = out_req_elems;
```

Conditions:

| Condition              | Behavior                                         |
| ---------------------- | ------------------------------------------------ |
| `occ >= pop_req_elems` | `out_valid = 1`, `out_num_elems = pop_req_elems` |
| `occ < pop_req_elems`  | `out_valid = 0`, `out_num_elems = don't care`    |

Pop occurs on rising edge if:

```systemverilog
pop_fire = out_valid && out_ready;
```

On a successful pop:

```systemverilog
occ_next = occ - out_num_elems;
```

> FIFO never asserts `out_valid` unless it can produce **exact** number of requested elements.

---

### **5.3 Simultaneous Push and Pop**

Both allowed.
Sequential effect:

```
occ_next = occ + pushed - popped
```

Ordering guarantee:

* Elements popped are those present **before** push in same cycle
* Newly pushed elements **cannot** be popped out same cycle

> First dequeue the oldest, then enqueue new ones.

---

## **8. Suggested Internal Architecture (Striped Banks)**

The external behavior above does **not** require a particular memory layout,
but a convenient implementation pattern is:

- Define `BANKS = max(IN_ELEMS_MAX, OUT_ELEMS_MAX)`.
- Implement `BANKS` instances of `sync_fifo`, each with depth `DEPTH` and
  width `ELEM_WIDTH` (one element per entry).
- Maintain global state in `vivo_fifo`:
  - `occ` = total element count across all banks (Section 4).
  - `rd_bank` = bank index holding the globally oldest element.
  - `wr_bank` = bank index where the next pushed element will be placed.
- When pushing `in_num_elems` elements:
  - Route input lane `j` to bank `(wr_bank + j) % BANKS`.
  - After a successful push, advance `wr_bank` by `in_num_elems` modulo `BANKS`
    and increase `occ` by `in_num_elems`.
- When popping `out_req_elems` elements:
  - Present output lane `i` from bank `(rd_bank + i) % BANKS`.
  - Only assert `out_valid` when `occ >= out_req_elems` (as in Section 5.2).
  - On a successful pop, advance `rd_bank` by `out_req_elems` modulo `BANKS`
    and decrease `occ` by `out_req_elems`.

This “striped” layout guarantees:

- Each bank sees at most one read and one write per cycle.
- Global ordering remains strict FIFO at element granularity.
- The total capacity in elements equals the top-level `DEPTH` parameter.

You are free to implement an equivalent architecture as long as
all externally observable semantics from Sections 3–6 are met.

---

## **6. Reset Behavior**

### **6.1 Asynchronous Assertion (`rst_n = 0`)**

Immediate:

* `occ = 0`
* All pointer state cleared
* `out_valid = 0`
* Data outputs and internal storage don’t care

No push/pop allowed during reset.

---

### **6.2 Reset Release**

On first clk rising edge with `rst_n == 1`:

* FIFO empty state
* `out_valid = 0`
* `in_ready = 1` (if entire transfer fits)

---

## **7. Legal / Illegal Inputs**

Assumptions guaranteed externally:

| Condition                                                 |
| --------------------------------------------------------- |
| `1 <= in_num_elems <= IN_ELEMS_MAX` when `in_valid = 1`   |
| `1 <= out_req_elems <= OUT_ELEMS_MAX` always              |
| Consumer ignores unused output lanes ≥ `out_num_elems`    |
| Producer only writes valid data in lanes `< in_num_elems` |

Illegal inputs → **undefined behavior** (no need to support).

---
