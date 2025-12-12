//------------------------------------------------------------------------------
// Simple synchronous FIFO (golden implementation, used by vivo_fifo_golden)
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

    localparam int PTR_W   = (DEPTH <= 1) ? 1 : $clog2(DEPTH);
    localparam int COUNT_W = (DEPTH <= 1) ? 1 : $clog2(DEPTH+1);

    logic [DEPTH-1:0][WIDTH-1:0] mem;
    logic [PTR_W-1:0]            wr_ptr;
    logic [PTR_W-1:0]            rd_ptr;
    logic [COUNT_W-1:0]          count;

    assign empty = (count == '0);
    assign full  = (count == DEPTH[COUNT_W-1:0]);

    // Asynchronous read from the current read pointer.
    assign rd_data = mem[rd_ptr];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= '0;
            rd_ptr <= '0;
            count  <= '0;
            mem    <= '0;
        end else begin
            logic do_wr;
            logic do_rd;

            do_wr = wr_en && !full;
            do_rd = rd_en && !empty;

            if (do_wr) begin
                mem[wr_ptr] <= wr_data;
                wr_ptr      <= (wr_ptr == DEPTH-1) ? '0 : wr_ptr + 1;
            end

            if (do_rd) begin
                rd_ptr <= (rd_ptr == DEPTH-1) ? '0 : rd_ptr + 1;
            end

            case ({do_wr, do_rd})
                2'b10: count <= count + 1;
                2'b01: count <= count - 1;
                default: /* 00 or 11 */ ;
            endcase
        end
    end

endmodule

