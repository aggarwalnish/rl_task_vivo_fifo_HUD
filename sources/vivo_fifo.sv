//------------------------------------------------------------------------------
// VIVO FIFO (Variable Input / Variable Output FIFO)
//------------------------------------------------------------------------------

module vivo_fifo #(
    parameter int ELEM_WIDTH     = 8,   // Width of each data element
    parameter int DEPTH          = 16,  // Total capacity in elements
    parameter int IN_ELEMS_MAX   = 4,   // Max elements that can be pushed per cycle
    parameter int OUT_ELEMS_MAX  = 4    // Max elements that can be popped per cycle
)(
    input  logic                           clk,
    input  logic                           rst_n, // Active low async reset

    // Push-side interface
    input  logic                                    in_valid,     // Incoming data valid
    output logic                                    in_ready,     // FIFO ready to accept
    input  logic [IN_ELEMS_MAX-1:0][ELEM_WIDTH-1:0] in_data,      // Packed 2D array input
    input  logic [$clog2(IN_ELEMS_MAX+1)-1:0]       in_num_elems, // Number of elems being pushed

    // Pop-side interface
    output logic                                     out_valid,     // FIFO has data to output
    input  logic                                     out_ready,     // Consumer ready for data
    output logic [OUT_ELEMS_MAX-1:0][ELEM_WIDTH-1:0] out_data,      // Packed 2D array output
    output logic [$clog2(OUT_ELEMS_MAX+1)-1:0]       out_num_elems, // Number of elems being popped
    input  logic [$clog2(OUT_ELEMS_MAX+1)-1:0]       out_req_elems  // Num requested by consumer
);

    // TODO: Implement FIFO internal memory structure

    // TODO: Define the safe defaults for the outputs

    // TODO: Implement write logic (store in_data when ready & valid)

    // TODO: Implement read logic (provide out_data when ready & valid)

endmodule
