//------------------------------------------------------------------------------
// VIVO FIFO (Variable Input / Variable Output FIFO)
// Golden implementation (striped multi-FIFO architecture)
//------------------------------------------------------------------------------

`include "sync_fifo.sv"

module vivo_fifo #(
    parameter int ELEM_WIDTH     = 8,
    // DEPTH is total element capacity (max elements stored).
    parameter int DEPTH          = 64,
    parameter int IN_ELEMS_MAX   = 4,
    parameter int OUT_ELEMS_MAX  = 4
)(
    input  logic                           clk,
    input  logic                           rst_n,   // active-low async reset

    // Push interface
    input  logic                                    in_valid,
    output logic                                    in_ready,
    input  logic [IN_ELEMS_MAX-1:0][ELEM_WIDTH-1:0] in_data,
    input  logic [$clog2(IN_ELEMS_MAX+1)-1:0]       in_num_elems,

    // Pop interface
    output logic                                     out_valid,
    input  logic                                     out_ready,
    output logic [OUT_ELEMS_MAX-1:0][ELEM_WIDTH-1:0] out_data,
    output logic [$clog2(OUT_ELEMS_MAX+1)-1:0]       out_num_elems,
    input  logic [$clog2(OUT_ELEMS_MAX+1)-1:0]       out_req_elems
);

    //--------------------------------------------------------------------------
    // Parameters / Derived constants
    //--------------------------------------------------------------------------

    localparam int BANKS      = (IN_ELEMS_MAX >= OUT_ELEMS_MAX)
                                ? IN_ELEMS_MAX : OUT_ELEMS_MAX;
    localparam int CAPACITY   = DEPTH; // total elements
    // Per-bank depth; rounded up so sum of banks can hold CAPACITY elements.
    localparam int BANK_DEPTH = (CAPACITY + BANKS - 1) / BANKS;

    localparam int COUNT_W  = $clog2(CAPACITY+1);
    localparam int BANK_W   = (BANKS <= 1) ? 1 : $clog2(BANKS);
    localparam int OUTW     = $clog2(OUT_ELEMS_MAX+1);

    //--------------------------------------------------------------------------
    // Internal state: global count and bank pointers
    //--------------------------------------------------------------------------

    typedef struct packed {
        logic [COUNT_W-1:0] count;
        logic [BANK_W-1:0]  rd_bank;
        logic [BANK_W-1:0]  wr_bank;
    } ptr_t;

    typedef struct packed {
        logic [OUT_ELEMS_MAX-1:0][ELEM_WIDTH-1:0] out_data;
        logic                                     out_valid;
        logic [OUTW-1:0]                          out_num_elems;
    } pop_t;

    ptr_t q_ptr, d_ptr;
    pop_t q_pop, d_pop;

    // Push / pop control
    logic [COUNT_W-1:0] free_space;
    logic               can_push;
    logic               do_push;

    logic               can_pop;
    logic               do_pop;

    // Per-bank FIFOs
    logic [BANKS-1:0]                     fifo_wr_en;
    logic [BANKS-1:0][ELEM_WIDTH-1:0]     fifo_wr_data;
    logic [BANKS-1:0]                     fifo_rd_en;
    logic [BANKS-1:0][ELEM_WIDTH-1:0]     fifo_rd_data;
    logic [BANKS-1:0]                     fifo_empty;
    logic [BANKS-1:0]                     fifo_full;

    //--------------------------------------------------------------------------
    // Instantiate per-bank synchronous FIFOs
    //--------------------------------------------------------------------------

    genvar b;
    generate
        for (b = 0; b < BANKS; b++) begin : gen_fifos
            sync_fifo #(
                .WIDTH (ELEM_WIDTH),
                .DEPTH (BANK_DEPTH)
            ) u_fifo (
                .clk     (clk),
                .rst_n   (rst_n),
                .wr_en   (fifo_wr_en[b]),
                .wr_data (fifo_wr_data[b]),
                .rd_en   (fifo_rd_en[b]),
                .rd_data (fifo_rd_data[b]),
                .empty   (fifo_empty[b]),
                .full    (fifo_full[b])
            );
        end
    endgenerate

    //--------------------------------------------------------------------------
    // Handshake / control signals
    //--------------------------------------------------------------------------

    assign free_space = CAPACITY - q_ptr.count;

    assign can_push = (in_num_elems != '0) &&
                       (in_num_elems <= free_space);

    assign in_ready = can_push;
    assign do_push  = in_valid && can_push;

    assign can_pop = (out_req_elems != '0) &&
                     (out_req_elems <= q_ptr.count);

    assign out_valid     = q_pop.out_valid;
    assign out_num_elems = q_pop.out_valid ? q_pop.out_num_elems : '0;
    assign out_data      = q_pop.out_data;

    assign do_pop = out_valid && out_ready;

    //--------------------------------------------------------------------------
    // Pointer and count updates
    //--------------------------------------------------------------------------

    always_comb begin
        d_ptr = q_ptr;

        d_ptr.count = q_ptr.count
                      + (do_push ? in_num_elems : '0)
                      - (do_pop  ? out_req_elems : '0);

        // rd_bank update (modulo BANKS)
        if (do_pop) begin
            if (BANKS > 1) begin
                d_ptr.rd_bank = (q_ptr.rd_bank + out_req_elems) % BANKS;
            end else begin
                d_ptr.rd_bank = '0;
            end
        end

        // wr_bank update (modulo BANKS)
        if (do_push) begin
            if (BANKS > 1) begin
                d_ptr.wr_bank = (q_ptr.wr_bank + in_num_elems) % BANKS;
            end else begin
                d_ptr.wr_bank = '0;
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q_ptr <= '0;
        end else begin
            q_ptr <= d_ptr;
        end
    end

    //--------------------------------------------------------------------------
    // Write distribution into per-bank FIFOs
    //--------------------------------------------------------------------------

    always_comb begin
        fifo_wr_en   = '0;
        fifo_wr_data = '0;

        if (do_push) begin
            for (int j = 0; j < IN_ELEMS_MAX; j++) begin
                if (j < in_num_elems) begin
                    int bank_idx;
                    bank_idx = (BANKS > 1) ? ((q_ptr.wr_bank + j) % BANKS) : 0;
                    fifo_wr_en[bank_idx]   = 1'b1;
                    fifo_wr_data[bank_idx] = in_data[j];
                end
            end
        end
    end

    //--------------------------------------------------------------------------
    // Pop datapath: prepare outputs (registered) and drive per-bank reads
    //--------------------------------------------------------------------------

    always_comb begin
        d_pop = q_pop;

        if (do_pop) begin
            // Pop completed: clear valid until next pop becomes ready
            d_pop = '0;
        end else if (can_pop) begin
            d_pop.out_valid     = 1'b1;
            d_pop.out_num_elems = out_req_elems;

            for (int i = 0; i < OUT_ELEMS_MAX; i++) begin
                if (i < out_req_elems) begin
                    int bank_idx;
                    bank_idx = (BANKS > 1) ? ((q_ptr.rd_bank + i) % BANKS) : 0;
                    d_pop.out_data[i] = fifo_rd_data[bank_idx];
                end else begin
                    d_pop.out_data[i] = '0;
                end
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q_pop <= '0;
        end else begin
            q_pop <= d_pop;
        end
    end

    // Generate per-bank read enables when a pop fires
    always_comb begin
        fifo_rd_en = '0;

        if (do_pop) begin
            for (int i = 0; i < OUT_ELEMS_MAX; i++) begin
                if (i < out_req_elems) begin
                    int bank_idx;
                    bank_idx = (BANKS > 1) ? ((q_ptr.rd_bank + i) % BANKS) : 0;
                    fifo_rd_en[bank_idx] = 1'b1;
                end
            end
        end
    end

endmodule
