`timescale 1ns/1ps

// ---------------------------------------------------------------------------
// kiosk_fsm (Mealy-like; all outputs registered)
// ---------------------------------------------------------------------------
module kiosk_fsm #(
    parameter ITEM_COUNT = 7,
    parameter ITEM_ID_W = 3,
    parameter QTY_W = 8,
    parameter PRICE_W = 16,
    parameter STOCK_W = 16,
    parameter TOKEN_W = 24,
    parameter MAX_LINES = 7,
    parameter SESSION_TIMER_W = 32,
    parameter [SESSION_TIMER_W-1:0] SESSION_TIMEOUT = 32'd100_000_000
)(
    input  wire                     clk,
    input  wire                     rst_n,

    // user pulses/data
    input  wire                     user_start_valid,
    input  wire                     sel_item_valid,
    input  wire [ITEM_ID_W-1:0]     sel_item_id,
    input  wire [QTY_W-1:0]         sel_qty,
    input  wire                     user_review_valid,
    input  wire                     user_confirm_valid,
    input  wire                     user_cancel_valid,
    input  wire [1:0]               payment_sel,
    input  wire                     payment_confirm_valid,

    // admin
    input  wire                     admin_req_valid,
    input  wire                     admin_auth_ok,
    output reg                      admin_deferred, // assert while session active

    // order buffer IF
    output reg                      ob_append_valid,
    output reg  [ITEM_ID_W-1:0]     ob_append_item,
    output reg  [QTY_W-1:0]         ob_append_qty,
    output reg                      ob_clear,
    input  wire                     ob_full,
    input  wire [2:0]               ob_len,
    output reg  [2:0]               ob_read_index,
    input  wire [ITEM_ID_W-1:0]     ob_read_item,
    input  wire [QTY_W-1:0]         ob_read_qty,

    // stock IF
    output reg  [ITEM_ID_W-1:0]     stock_rd_addr,
    input  wire [STOCK_W-1:0]       stock_rd_data,
    output reg                      stock_wr_en,
    output reg  [ITEM_ID_W-1:0]     stock_wr_addr,
    output reg  [STOCK_W-1:0]       stock_wr_data,

    // price IF (reads only)
    output reg  [ITEM_ID_W-1:0]     price_rd_addr,
    input  wire [PRICE_W-1:0]       price_rd_data,

    // token IF
    output reg                      tm_issue_req,
    output reg  [31:0]              tm_meta_in,
    input  wire                     tm_issued_valid,
    input  wire [TOKEN_W-1:0]       tm_token_id,
    input  wire                     tm_overflow_err,

    // outputs
    output reg                      token_issued_valid,
    output reg  [TOKEN_W-1:0]       token_id,
    output reg                      receipt_valid,
    output reg  [255:0]             receipt_data,
);
    // State encoding
    localparam S_IDLE              = 4'd0;
    localparam S_SESSION_START     = 4'd1;
    localparam S_USER_SELECT       = 4'd2;
    localparam S_USER_REVIEW       = 4'd3;
    localparam S_CHECK_STOCK_INIT  = 4'd4;
    localparam S_CHECK_STOCK       = 4'd5;
    localparam S_WAIT_PAYMENT      = 4'd6;
    localparam S_GEN_TOKEN         = 4'd7;
    localparam S_PRICE_INIT        = 4'd8;
    localparam S_PRICE_READ        = 4'd9;
    localparam S_STOCK_DECR_INIT   = 4'd10;
    localparam S_STOCK_DECR        = 4'd11;
    localparam S_ISSUE_RECEIPT     = 4'd12;
    localparam S_COMPLETE          = 4'd13;
    
    // Error/aux states
    localparam S_REJECT            = 4'd14;
    localparam S_SESSION_TIMEOUT_S = 4'd15;

    localparam S_ADMIN_AUTH   = 4'd16;
    localparam S_ADMIN_MODE   = 4'd17;

    reg [3:0] state;
    reg [3:0] next_state;

    // temps/counters
    reg [2:0] line_idx;
    reg [SESSION_TIMER_W-1:0] session_timer;
    reg stock_ok;
    reg [31:0] running_total; // smallest unit of money chosen
    reg [ITEM_ID_W-1:0] current_item;
    reg [QTY_W-1:0]     current_qty;

    // store the value returned by RAM so the FSM can use a stable copy of the data in the next clock cycles.
    reg [STOCK_W-1:0] stock_sampled;
    reg [PRICE_W-1:0] price_sampled;

    wire order_empty = (ob_len == 3'd0); // checks whether the order buffer currently has zero items.
    wire item_id_valid = (sel_item_id < ITEM_COUNT); // verifies whether the item ID chosen by the user is valid.

    always @(*) begin
        next_state = state; // we default to staying in the same state unless a transition condition is met that changes next_state.
    end

    // State register
    always @(posedge clk) begin
        if (!rst_n) state <= S_IDLE;
        else        state <= next_state;
    end

    // Main sequential
    always @(posedge clk) begin
        if (!rst_n) begin
            // resets
            ob_append_valid   <= 1'b0;
            ob_append_item    <= {ITEM_ID_W{1'b0}};
            ob_append_qty     <= {QTY_W{1'b0}};
            ob_clear          <= 1'b1;
            ob_read_index     <= 3'b0;

            stock_rd_addr     <= {ITEM_ID_W{1'b0}};
            stock_wr_en       <= 1'b0;
            stock_wr_addr     <= {ITEM_ID_W{1'b0}};
            stock_wr_data     <= {STOCK_W{1'b0}};

            price_rd_addr     <= {ITEM_ID_W{1'b0}};

            tm_issue_req      <= 1'b0;
            tm_meta_in        <= 32'b0;

            token_issued_valid<= 1'b0;
            token_id          <= {TOKEN_W{1'b0}};
            receipt_valid     <= 1'b0;
            receipt_data      <= 256'b0;

            err_led           <= 1'b0;

            line_idx          <= 3'b0;
            session_timer     <= {SESSION_TIMER_W{1'b0}};
            stock_ok          <= 1'b1;
            running_total     <= 32'b0;

            admin_deferred    <= 1'b0;
        end else begin
            // defaults
            ob_append_valid   <= 1'b0;
            ob_clear          <= 1'b0;
            stock_wr_en       <= 1'b0;
            tm_issue_req      <= 1'b0;
            token_issued_valid<= 1'b0;
            receipt_valid     <= 1'b0;
            

            // session timer
            if (state==S_USER_SELECT || state==S_USER_REVIEW || state==S_WAIT_PAYMENT) begin
                session_timer <= session_timer + 1'b1;
            end else begin
                session_timer <= {SESSION_TIMER_W{1'b0}};
            end

            // admin deferral: assert while not IDLE
            admin_deferred <= (state != S_IDLE); // admin is helpless if any other state is current state

            case (state)
                S_IDLE: begin
                    running_total   <= 32'b0;
                    line_idx        <= 3'b0; // what is line index used for? -> used to index through the order buffer lines during review, stock check, price calculation, etc.

                    if (user_start_valid) begin
                        ob_clear        <= 1'b1;
                        state           <= S_SESSION_START;
                    end else if (admin_req_valid) begin
                        state           <= S_ADMIN_AUTH;
                    end else begin
                        state <= S_IDLE;
                    end
                end

                S_ADMIN_AUTH: begin
                    if (admin_auth_ok) begin
                        state <= S_ADMIN_MODE;
                    end else if (!admin_req_valid) begin
                        state <= S_IDLE;
                    end
                end

                S_ADMIN_MODE: begin
                    // Admin commands are executed through admin_if
                    // FSM just stays in admin mode until admin exits
                    if (!admin_req_valid) begin
                        state <= S_IDLE; // exit admin mode
                    end
                end


                S_SESSION_START: begin
                    state <= S_USER_SELECT;
                end

                S_USER_SELECT: begin
                    if (session_timer >= SESSION_TIMEOUT) begin
                        ob_clear        <= 1'b1;
                        state           <= S_SESSION_TIMEOUT_S;
                    end else if (admin_req_valid) begin
                        state <= S_USER_SELECT;
                    end else if (user_cancel_valid) begin
                        ob_clear <= 1'b1;
                        state    <= S_IDLE;
                    end else if (sel_item_valid) begin
                        if (ob_full) begin
                            // buffer full -> hard reject with code
                            state           <= S_REJECT;
                        end else if (!item_id_valid || (sel_qty == {QTY_W{1'b0}})) begin
                            // invalid selection -> ignore but give feedback
                            state           <= S_USER_SELECT;
                        end else begin
                            ob_append_valid <= 1'b1;
                            ob_append_item  <= sel_item_id;
                            ob_append_qty   <= sel_qty;
                            state           <= S_USER_SELECT;
                        end
                    end else if (user_review_valid) begin
                        state <= S_USER_REVIEW;
                    end
                end

                S_USER_REVIEW: begin
                    if (session_timer >= SESSION_TIMEOUT) begin
                        display_msg_out <= 8'hEE;
                        ob_clear <= 1'b1;
                        state    <= S_SESSION_TIMEOUT_S;
                    end else if (admin_req_valid) begin
                        state <= S_USER_REVIEW;
                    end else if (user_cancel_valid) begin
                        ob_clear <= 1'b1;
                        state    <= S_IDLE;
                    end else if (user_confirm_valid) begin
                        if (order_empty) begin
                            // Empty confirm -> reject
                            state           <= S_REJECT;
                        end else begin
                            // start stock checking
                            line_idx      <= 3'd0;
                            ob_read_index <= 3'd0;
                            stock_rd_addr <= ob_read_item; // kicks first read
                            state         <= S_CHECK_STOCK_INIT;
                        end
                    end
                end

                S_CHECK_STOCK_INIT: begin
                    // Wait one cycle for first rd_data
                    state <= S_CHECK_STOCK;
                end

                S_CHECK_STOCK: begin
                    // sample and compare
                    stock_sampled <= stock_rd_data;
                    current_item  <= ob_read_item;
                    current_qty   <= ob_read_qty;

                    if (stock_rd_data < ob_read_qty) begin
                        stock_ok        <= 1'b0;
                        // ERR: out of stock
                        state           <= S_REJECT;
                    end else begin
                        // Advance
                        if ((line_idx + 1) < ob_len) begin
                            line_idx      <= line_idx + 1'b1;
                            ob_read_index <= line_idx + 1'b1;
                            stock_rd_addr <= ob_read_item; // set up next read
                            state         <= S_CHECK_STOCK;
                        end else begin
                            // all ok -> payment
                            state           <= S_WAIT_PAYMENT;
                        end
                    end
                end

                S_WAIT_PAYMENT: begin
                    if (session_timer >= SESSION_TIMEOUT) begin
                        ob_clear <= 1'b1;
                        state    <= S_SESSION_TIMEOUT_S;
                    end else if (user_cancel_valid) begin
                        // Allow cancel during payment wait
                        ob_clear <= 1'b1;
                        state    <= S_IDLE;
                    end else if (payment_confirm_valid) begin
                        // Request token now
                        tm_issue_req <= 1'b1;
                        tm_meta_in   <= {24'b0, ob_len};
                        state        <= S_GEN_TOKEN;
                    end
                end

                S_GEN_TOKEN: begin
                    // Keep waiting for token OR overflow error
                    if (tm_overflow_err) begin
                        ob_clear        <= 1'b1;
                        state           <= S_REJECT;
                    end else if (tm_issued_valid) begin
                        token_id        <= tm_token_id;
                        token_issued_valid <= 1'b1; // pulse
                        // prepare price accumulation
                        running_total   <= 32'b0;
                        line_idx        <= 3'd0;
                        ob_read_index   <= 3'd0;
                        price_rd_addr   <= ob_read_item; // kick first price read
                        state           <= S_PRICE_INIT;
                    end
                end

                S_PRICE_INIT: begin
                    // wait one cycle for first price
                    state <= S_PRICE_READ;
                end

                S_PRICE_READ: begin
                    // accumulate price*qty
                    price_sampled <= price_rd_data; // sample price read from RAM for current line so we have a stable value to work with in the next cycles while we decide how to advance through the order buffer and calculate totals.
                    // Multiply (price 16-bit * qty up to 8-bit -> 24-bit; accumulate into 32-bit)
                    running_total <= running_total + (price_rd_data * ob_read_qty);

                    // advance
                    if ((line_idx + 1) < ob_len) begin
                        line_idx      <= line_idx + 1'b1;
                        ob_read_index <= line_idx + 1'b1;
                        price_rd_addr <= ob_read_item; // set next read
                        state         <= S_PRICE_READ; // stays; next cycle will use new data
                    end else begin
                        // finished totals -> do stock decrement pass
                        line_idx      <= 3'd0;
                        ob_read_index <= 3'd0;
                        // setup first write next
                        state         <= S_STOCK_DECR_INIT;
                    end
                end

                S_STOCK_DECR_INIT: begin
                    // Read current stock (already read earlier, but re-read to be robust)
                    stock_rd_addr <= ob_read_item;
                    state         <= S_STOCK_DECR;
                end

                S_STOCK_DECR: begin
                    // write back decremented stock for current line
                    stock_wr_en   <= 1'b1;
                    stock_wr_addr <= ob_read_item;
                    stock_wr_data <= (stock_rd_data >= ob_read_qty) ? (stock_rd_data - ob_read_qty) : stock_rd_data; // defensive: only decrement if we have enough stock, otherwise write back original value (should not happen since we checked earlier, but just in case)

                    if ((line_idx + 1) < ob_len) begin
                        line_idx      <= line_idx + 1'b1;
                        ob_read_index <= line_idx + 1'b1;
                        stock_rd_addr <= ob_read_item; // prepare next read
                        state         <= S_STOCK_DECR;
                    end else begin
                        state <= S_ISSUE_RECEIPT;
                    end
                end

                S_ISSUE_RECEIPT: begin
                    receipt_data          <= 256'b0;
                    receipt_data[219:208] <= token_id;
                    receipt_data[207:176] <= running_total;
                    receipt_data[175:168] <= {5'b0, ob_len};
                    receipt_valid         <= 1'b1; // true

                    state           <= S_COMPLETE;
                end

                S_COMPLETE: begin
                    ob_clear        <= 1'b1;
                    state           <= S_IDLE;
                end

                S_REJECT: begin
                    state     <= S_IDLE;
                end

                S_SESSION_TIMEOUT_S: begin
                    state     <= S_IDLE;
                end

                default: begin
                    state <= S_IDLE;
                end
            endcase
        end
    end
endmodule

