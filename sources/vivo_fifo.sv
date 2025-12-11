//------------------------------------------------------------------------------
// VIVO FIFO (Variable Input / Variable Output FIFO)
// Golden implementation
//------------------------------------------------------------------------------

module vivo_fifo #(
    parameter int ELEM_WIDTH     = 8,
    // DEPTH is number of "rows" in memory; each row can hold BANKS elements.
    // Total element capacity = DEPTH * BANKS (where BANKS = max(IN_ELEMS_MAX, OUT_ELEMS_MAX)).
    parameter int DEPTH          = 16,
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

    localparam int BANKS = (IN_ELEMS_MAX >= OUT_ELEMS_MAX)
                           ? IN_ELEMS_MAX : OUT_ELEMS_MAX;

    // Total memory/buffer capacity.
    localparam int CAPACITY = DEPTH * BANKS;

    // Widths for element index and count.
    localparam int IDX_W    = $clog2(CAPACITY);
    localparam int COUNT_W  = $clog2(CAPACITY+1);
    localparam int OUTW     = $clog2(OUT_ELEMS_MAX+1);

    //--------------------------------------------------------------------------
    // Internal logic
    //--------------------------------------------------------------------------    

    logic [DEPTH-1:0][BANKS-1:0][ELEM_WIDTH-1:0] mem; 

    // Pointers 
    typedef struct packed {
        logic [IDX_W-1:0]   wr_idx;
        logic [IDX_W-1:0]   rd_idx;
        logic [COUNT_W-1:0] count; 
    } ptr_t;
    
    // Output interface
    typedef struct packed{
        logic [OUT_ELEMS_MAX-1:0][ELEM_WIDTH-1:0] out_data;
        logic                                     out_valid;
        logic [OUTW-1:0]                          out_num_elems;
    } pop_t;

    ptr_t d_ptr, q_ptr;
    pop_t d_pop, q_pop;

    // Push interface
    logic [COUNT_W-1:0] free_space;
    logic               can_push;
    logic               do_push;

    // Pop interface
    logic               can_pop;
    logic               do_pop; 

    //--------------------------------------------------------------------------
    // Helper function: map element index -> (row, bank)
    //--------------------------------------------------------------------------

    function automatic void idx_to_row_bank(
        input  logic [IDX_W-1:0] idx,
        output int               row,
        output int               bank
    );
        int tmp;
        begin
            tmp  = idx;
            row  = tmp / BANKS;
            bank = tmp % BANKS;
        end
    endfunction

    //--------------------------------------------------------------------------
    // in-ready
    //--------------------------------------------------------------------------

    assign free_space = CAPACITY - q_ptr.count;

    assign can_push = (in_num_elems <= free_space) && (in_num_elems != '0);
    assign in_ready = can_push;  // combinational

    assign do_push = in_valid && can_push;

    //--------------------------------------------------------------------------
    // Pop interface
    //--------------------------------------------------------------------------

    assign can_pop = (out_req_elems != '0) &&
                     (out_req_elems <= q_ptr.count);

    assign do_pop  = out_valid && out_ready;

    // Registered outputs
    assign out_valid     = q_pop.out_valid;
    assign out_num_elems = q_pop.out_valid ? q_pop.out_num_elems : '0;
    assign out_data      = q_pop.out_data;

    //--------------------------------------------------------------------------
    // Sequential logic: reset, push, pop, pointer and count updates
    //--------------------------------------------------------------------------

    // Pointer and count updates
    always_comb
    begin
        d_ptr = q_ptr;
        
        d_ptr.wr_idx = do_push ? 
                       ((q_ptr.wr_idx + in_num_elems) % CAPACITY ) : 
                       q_ptr.wr_idx;
        
        d_ptr.rd_idx = do_pop ? 
                       ((q_ptr.rd_idx + out_req_elems) % CAPACITY ) : 
                       q_ptr.rd_idx;

        d_ptr.count  = q_ptr.count + (do_push ? in_num_elems : 0) - 
                       (do_pop  ? out_req_elems : 0);
    end

    always_ff @(posedge clk or negedge rst_n)
    begin
        if (!rst_n) begin
            q_ptr <= '0;
        end
        else begin
            q_ptr <= d_ptr;
        end
    end

    // Memory read (pop)
    always_comb
    begin
        d_pop = q_pop;

        if(do_pop)
        begin
            d_pop = '0;
        end
        else if(can_pop)
        begin
            d_pop.out_valid    = 1'b1;
            d_pop.out_num_elems = out_req_elems;

            for (int i = 0; i < OUT_ELEMS_MAX; i++) begin
                if (i < out_req_elems) begin
                    logic [IDX_W-1:0] idx_elem;
                    int row, bank;
                    idx_elem = q_ptr.rd_idx + i;
                    idx_elem = idx_elem % CAPACITY;
                    idx_to_row_bank(idx_elem, row, bank);
                    d_pop.out_data[i] = mem[row][bank];
                end
                else begin
                    d_pop.out_data[i] = '0;
                end
            end
        end
    end

    always_ff @(posedge clk, negedge rst_n)
    begin
        if (!rst_n) begin
            q_pop <= '0;
        end
        else begin
            q_pop <= d_pop;
        end
    end

    // Memory write (push)
    always_ff @(posedge clk, negedge rst_n)
    begin
        if (!rst_n) begin
            mem <= '0;
        end
        else if (do_push) begin
            for (int j = 0; j < IN_ELEMS_MAX; j++)
            begin
                if (j < in_num_elems) begin
                    logic [IDX_W-1:0] idx_elem;
                    int row, bank;
                    idx_elem = q_ptr.wr_idx + j;
                    idx_elem = idx_elem % CAPACITY;
                    idx_to_row_bank(idx_elem, row, bank);
                    mem[row][bank] <= in_data[j];
                end
            end
        end
    end

endmodule
