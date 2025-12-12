//------------------------------------------------------------------------------
// Simple synchronous FIFO (used by vivo_fifo)
//
// Baseline stub:
//   - Parameterized by WIDTH (bits per element) and DEPTH (entries)
//   - One write port (wr_en/wr_data)
//   - One read port (rd_en/rd_data)
//   - Status outputs: empty/full
//
// You must implement a synthesizable, single-clock FIFO that:
//   - Uses only posedge clk, async active-low rst_n
//   - Never overflows or underflows internally
//   - Preserves strict ordering of written elements
//   - Can be instantiated in parallel by vivo_fifo
//
// Internal implementation is intentionally left blank for the agent to fill in.
//------------------------------------------------------------------------------

module sync_fifo #(
    parameter int WIDTH = 8,
    parameter int DEPTH = 16
)(
    input  logic             clk,
    input  logic             rst_n,   // active-low async reset
    input  logic             wr_en,
    input  logic [WIDTH-1:0] wr_data,
    input  logic             rd_en,
    output logic [WIDTH-1:0] rd_data,
    output logic             empty,
    output logic             full
);

    // TODO: Add internal memory, pointers, and count
    // TODO: Implement write path with back-to-back writes allowed
    // TODO: Implement read path with registered or combinational rd_data
    // TODO: Drive empty/full correctly based on occupancy

endmodule

