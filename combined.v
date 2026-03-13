`timescale 1ns/1ps

/*
    module moduleName (
        // ports -> 3 types
    );
*/

module Cafeteria (
    input  wire         clk,
    input  wire         rst_n,

    // Raw push buttons / inputs external should be debounced and sampled to pulses
    input  wire         user_start_btn,
    input  wire         sel_item_btn,       // pulse when item selection is provided; paired with sel_item_id and sel_qty
    input  wire [2:0]   sel_item_id,  // item ID selected (0 to 6 for 7 items) eg 111,101,100
    input  wire [7:0]   sel_qty,     // quantity selected (1 to 255)
    input  wire         user_review_btn,
    input  wire         user_confirm_btn,
    input  wire         user_cancel_btn,
    input  wire [1:0]   payment_sel,        // 00:UPI,01:CARD,10:OTHER
    input  wire         payment_confirm_btn,

    // Admin maintenance interface (separate access)
    input  wire         admin_req_btn,
    input  wire         admin_pw_valid,
    input  wire [31:0]  admin_pw,           // 8-digit decimal encoded in binary (example)
    input  wire         admin_cmd_valid,
    input  wire [3:0]   admin_cmd,          // 0x1 price write, 0x2 stock write, 0x3 token cancel, 0x4 change PW
    input  wire [31:0]  admin_payload,

    // Outputs
    output wire         token_issued_valid,
    output wire [23:0]  token_id,
    output wire         receipt_valid,
    output wire [255:0] receipt_data,       // packed receipt (token|total|len etc.)
    output wire [7:0]   display_msg,
);

    // -----------------------------------------------------------------------
    // Parameters
    // -----------------------------------------------------------------------
    localparam ITEM_COUNT      = 7; // used to perform checks
    localparam ITEM_ID_W       = 3; // bits
    localparam QTY_W           = 8; // bits
    localparam PRICE_W         = 16; // bits
    localparam STOCK_W         = 16; // bits
    localparam TOKEN_W         = 24; //bits
    localparam MAX_LINES       = 7; // used to check the order buffer
    localparam SESSION_TIMER_W = 32; // bits for session timer
    localparam SESSION_TIMEOUT = 32'd500_000_000; // 32'd500_000_000 means 32 bit number with decimalvalue and 500million value => 10 seconds

    // -----------------------------------------------------------------------
    // Debounce/sample to one-cycle pulses 000011111111 => 000000000001
    // -----------------------------------------------------------------------
    wire user_start_valid, sel_item_valid, user_review_valid, user_confirm_valid, user_cancel_valid, payment_confirm_valid, admin_req_valid;

    // debounce_sampler module: takes raw button inputs and produces one-cycle valid pulses for FSM; also samples item ID and qty for sel_item_btn

    debounce_sampler #(.N(6)) db (
        .clk(clk), .rst_n(rst_n),
        .btn_user_start(user_start_btn),
        .btn_sel_item(sel_item_btn),
        .btn_user_review(user_review_btn),
        .btn_user_confirm(user_confirm_btn),
        .btn_user_cancel(user_cancel_btn),
        .btn_payment_confirm(payment_confirm_btn),
        .btn_admin_req(admin_req_btn),

        .user_start_pulse(user_start_valid), // . notation matches here 
        .sel_item_pulse(sel_item_valid),
        .user_review_pulse(user_review_valid),
        .user_confirm_pulse(user_confirm_valid),
        .user_cancel_pulse(user_cancel_valid),
        .payment_confirm_pulse(payment_confirm_valid),
        .admin_req_pulse(admin_req_valid)
    );

    // Sampled data buses 
    wire [ITEM_ID_W-1:0] sel_item_id_in = sel_item_id[ITEM_ID_W-1:0]; // this is a collection of wires 
    wire [QTY_W-1:0]     sel_qty_in     = sel_qty[QTY_W-1:0];

    // -----------------------------------------------------------------------
    // Memories / tables
    // -----------------------------------------------------------------------
    // Stock RAM
    wire [ITEM_ID_W-1:0] stock_rd_addr;
    wire [STOCK_W-1:0]   stock_rd_data;

    // Write arbitration signals (FSM/admin)
    wire                  fsm_stock_wr_en;
    wire [ITEM_ID_W-1:0]  fsm_stock_wr_addr;
    wire [STOCK_W-1:0]    fsm_stock_wr_data;
    wire                  adm_stock_wr_en;
    wire [ITEM_ID_W-1:0]  adm_stock_wr_addr;
    wire [STOCK_W-1:0]    adm_stock_wr_data;

    // Arb: FSM has priority during purchase; admin otherwise ==> meaning if FSM is trying to write, admin write is blocked; if FSM not writing, admin can write
    wire stock_wr_en          = fsm_stock_wr_en | (adm_stock_wr_en & ~fsm_stock_wr_en);
    wire [ITEM_ID_W-1:0] stock_wr_addr = fsm_stock_wr_en ? fsm_stock_wr_addr : adm_stock_wr_addr;
    wire [STOCK_W-1:0]   stock_wr_data = fsm_stock_wr_en ? fsm_stock_wr_data : adm_stock_wr_data;

    stock_ram #(
        .ITEM_COUNT(ITEM_COUNT),
        .ADDR_W(ITEM_ID_W),
        .DATA_W(STOCK_W)
    ) stock_i (
        .clk(clk), .rst_n(rst_n),
        .rd_addr(stock_rd_addr), .rd_data(stock_rd_data),
        .wr_en(stock_wr_en), .wr_addr(stock_wr_addr), .wr_data(stock_wr_data)
    );

    // Price table (FSM reads for totals; admin writes)
    wire [ITEM_ID_W-1:0] price_rd_addr;
    wire [PRICE_W-1:0]   price_rd_data;
    wire                  adm_price_wr_en;
    wire [ITEM_ID_W-1:0]  adm_price_wr_addr;
    wire [PRICE_W-1:0]    adm_price_wr_data;

    price_table #(
        .ITEM_COUNT(ITEM_COUNT),
        .ADDR_W(ITEM_ID_W),
        .DATA_W(PRICE_W)
    ) price_i (
        .clk(clk), .rst_n(rst_n),
        .rd_addr(price_rd_addr), .rd_data(price_rd_data),
        .wr_en(adm_price_wr_en), .wr_addr(adm_price_wr_addr), .wr_data(adm_price_wr_data)
    );

    // -----------------------------------------------------------------------
    // Order buffer (session)
    // -----------------------------------------------------------------------
    wire                        ob_append_valid;
    wire [ITEM_ID_W-1:0]        ob_append_item;
    wire [QTY_W-1:0]            ob_append_qty;
    wire                        ob_full;
    wire [2:0]                  ob_len;
    wire                        ob_clear;
    wire [2:0]                  ob_read_index;
    wire [ITEM_ID_W-1:0]        ob_read_item;
    wire [QTY_W-1:0]            ob_read_qty;

    order_buffer #(
        .MAX_LINES(MAX_LINES),
        .ITEM_ID_W(ITEM_ID_W),
        .QTY_W(QTY_W)
    ) orderbuf_i (
        .clk(clk), .rst_n(rst_n),
        .append_valid(ob_append_valid),
        .append_item(ob_append_item),
        .append_qty(ob_append_qty),
        .clear(ob_clear),
        .full(ob_full),
        .len(ob_len),
        .read_index(ob_read_index),
        .read_item(ob_read_item),
        .read_qty(ob_read_qty)
    );

    // -----------------------------------------------------------------------
    // Token manager 
    // -----------------------------------------------------------------------
    wire                         tm_issue_req;
    wire [31:0]                  tm_meta_in;
    wire                         tm_issued_valid;
    wire [TOKEN_W-1:0]           tm_token_id;
    wire                         tm_cancel_req;
    wire [TOKEN_W-1:0]           tm_cancel_id;
    wire [1:0]                   tm_token_status;
    wire                         tm_overflow_err; 
    wire                         tm_bulk_cancel_req;   

    token_manager #(
        .TOKEN_W(TOKEN_W),
        .DEPTH(4096)
    ) token_i (
        .clk(clk), .rst_n(rst_n),
        .issue_req(tm_issue_req),
        .meta_in(tm_meta_in),
        .issued_valid(tm_issued_valid),
        .token_id(tm_token_id),
        .cancel_req(tm_cancel_req),
        .cancel_id(tm_cancel_id),
        .token_status(tm_token_status),
        .overflow_err(tm_overflow_err)
        .bulk_cancel_req(tm_bulk_cancel_req),
    );

    // -----------------------------------------------------------------------
    // Admin interface
    // -----------------------------------------------------------------------
    wire admin_auth_ok;
    wire admin_deferred; // from FSM: busy during session, show BUSY if admin tries

    // Unmasked admin write wires (outputs of admin_if)
    wire                  adm_price_wr_en_unmasked;
    wire [ITEM_ID_W-1:0]  adm_price_wr_addr_unmasked;
    wire [PRICE_W-1:0]    adm_price_wr_data_unmasked;

    wire                  adm_stock_wr_en_unmasked;
    wire [ITEM_ID_W-1:0]  adm_stock_wr_addr_unmasked;
    wire [STOCK_W-1:0]    adm_stock_wr_data_unmasked;

    // Masked wires to price/stock tables (after deferral gate)
    assign adm_price_wr_en   = admin_deferred ? 1'b0 : adm_price_wr_en_unmasked;
    assign adm_price_wr_addr = adm_price_wr_addr_unmasked;
    assign adm_price_wr_data = adm_price_wr_data_unmasked;

    assign adm_stock_wr_en   = admin_deferred ? 1'b0 : adm_stock_wr_en_unmasked;
    assign adm_stock_wr_addr = adm_stock_wr_addr_unmasked;
    assign adm_stock_wr_data = adm_stock_wr_data_unmasked;

    admin_if #(
        .PW_W(32)
    ) admin_i (
        .clk(clk), .rst_n(rst_n),
        .admin_req_valid(admin_req_valid),
        .admin_pw_valid(admin_pw_valid),
        .admin_pw(admin_pw),
        .admin_cmd_valid(admin_cmd_valid),
        .admin_cmd(admin_cmd),
        .admin_payload(admin_payload),

        // writes out (subject to top arbitration & FSM busy gate)
        .price_wr_en(adm_price_wr_en_unmasked),
        .price_wr_addr(adm_price_wr_addr_unmasked),
        .price_wr_data(adm_price_wr_data_unmasked),

        .stock_wr_en(adm_stock_wr_en_unmasked),
        .stock_wr_addr(adm_stock_wr_addr_unmasked),
        .stock_wr_data(adm_stock_wr_data_unmasked),

        .token_cancel_req(tm_cancel_req),
        .token_cancel_id(tm_cancel_id),
        .token_bulk_cancel_req(tm_bulk_cancel_req),

        .auth_ok(admin_auth_ok)
    );

    // -----------------------------------------------------------------------
    // FSM
    // -----------------------------------------------------------------------

    kiosk_fsm #(
        .ITEM_COUNT(ITEM_COUNT),
        .ITEM_ID_W(ITEM_ID_W),
        .QTY_W(QTY_W),
        .PRICE_W(PRICE_W),
        .STOCK_W(STOCK_W),
        .TOKEN_W(TOKEN_W),
        .MAX_LINES(MAX_LINES),
        .SESSION_TIMER_W(SESSION_TIMER_W),
        .SESSION_TIMEOUT(SESSION_TIMEOUT)
    ) fsm_i (
        .clk(clk), .rst_n(rst_n),

        // user inputs (sampled pulses)
        .user_start_valid(user_start_valid),
        .sel_item_valid(sel_item_valid),
        .sel_item_id(sel_item_id_in),
        .sel_qty(sel_qty_in),
        .user_review_valid(user_review_valid),
        .user_confirm_valid(user_confirm_valid),
        .user_cancel_valid(user_cancel_valid),
        .payment_sel(payment_sel),
        .payment_confirm_valid(payment_confirm_valid),

        // admin
        .admin_req_valid(admin_req_valid),
        .admin_auth_ok(admin_auth_ok),
        .admin_deferred(admin_deferred), // output that tells top to block admin writes during session

        // order buffer IF
        .ob_append_valid(ob_append_valid),
        .ob_append_item(ob_append_item),
        .ob_append_qty(ob_append_qty),
        .ob_clear(ob_clear),
        .ob_full(ob_full),
        .ob_len(ob_len),
        .ob_read_index(ob_read_index),
        .ob_read_item(ob_read_item),
        .ob_read_qty(ob_read_qty),

        // stock IF
        .stock_rd_addr(stock_rd_addr),
        .stock_rd_data(stock_rd_data),
        .stock_wr_en(fsm_stock_wr_en),
        .stock_wr_addr(fsm_stock_wr_addr),
        .stock_wr_data(fsm_stock_wr_data),

        // price IF (FSM reads only)
        .price_rd_addr(price_rd_addr),
        .price_rd_data(price_rd_data),

        // token IF
        .tm_issue_req(tm_issue_req),
        .tm_meta_in(tm_meta_in),
        .tm_issued_valid(tm_issued_valid),
        .tm_token_id(tm_token_id),
        .tm_overflow_err(tm_overflow_err),

        // top outputs
        .token_issued_valid(token_issued_valid),
        .token_id(token_id),
        .receipt_valid(receipt_valid),
        .receipt_data(receipt_data),
    );

endmodule

`timescale 1ns/1ps

// ---------------------------------------------------------------------------
// debounce_sampler
// ---------------------------------------------------------------------------
module debounce_sampler #(parameter N = 6) (
    input  wire clk,
    input  wire rst_n,
    input  wire btn_user_start,
    input  wire btn_sel_item,
    input  wire btn_user_review,
    input  wire btn_user_confirm,
    input  wire btn_user_cancel,
    input  wire btn_payment_confirm,
    input  wire btn_admin_req,

    output reg  user_start_pulse,  // 000001111111 => 000000000001
    output reg  sel_item_pulse,
    output reg  user_review_pulse,
    output reg  user_confirm_pulse,
    output reg  user_cancel_pulse,
    output reg  payment_confirm_pulse,
    output reg  admin_req_pulse
);
    reg prev_user_start, prev_sel_item, prev_user_review, prev_user_confirm, prev_user_cancel, prev_payment_confirm, prev_admin_req;

    always @(posedge clk) begin
        if (!rst_n) begin
            prev_user_start      <= 1'b0; 
            prev_sel_item        <= 1'b0;
            prev_user_review     <= 1'b0;
            prev_user_confirm    <= 1'b0;
            prev_user_cancel     <= 1'b0;
            prev_payment_confirm <= 1'b0;
            prev_admin_req       <= 1'b0;

            user_start_pulse     <= 1'b0;
            sel_item_pulse       <= 1'b0;
            user_review_pulse    <= 1'b0;
            user_confirm_pulse   <= 1'b0;
            user_cancel_pulse    <= 1'b0;
            payment_confirm_pulse<= 1'b0;
            admin_req_pulse      <= 1'b0;
        end else begin
            user_start_pulse      <= btn_user_start      && !prev_user_start;
            sel_item_pulse        <= btn_sel_item        && !prev_sel_item;
            user_review_pulse     <= btn_user_review     && !prev_user_review;
            user_confirm_pulse    <= btn_user_confirm    && !prev_user_confirm;
            user_cancel_pulse     <= btn_user_cancel     && !prev_user_cancel;
            payment_confirm_pulse <= btn_payment_confirm && !prev_payment_confirm;
            admin_req_pulse       <= btn_admin_req       && !prev_admin_req;

            // btn:    0 0 1 1 1
            // pulse:  0 0 1 0 0   

            // backup current button states for next cycle
            prev_user_start      <= btn_user_start;
            prev_sel_item        <= btn_sel_item;
            prev_user_review     <= btn_user_review;
            prev_user_confirm    <= btn_user_confirm;
            prev_user_cancel     <= btn_user_cancel;
            prev_payment_confirm <= btn_payment_confirm;
            prev_admin_req       <= btn_admin_req;
        end
    end
endmodule

`timescale 1ns/1ps

// ---------------------------------------------------------------------------
// admin_if
// ---------------------------------------------------------------------------
module admin_if #(
    parameter PW_W = 32
)(
    input  wire         clk,
    input  wire         rst_n,
    input  wire         admin_req_valid,
    input  wire         admin_pw_valid,
    input  wire [PW_W-1:0] admin_pw,
    input  wire         admin_cmd_valid,
    input  wire [3:0]   admin_cmd,
    input  wire [31:0]  admin_payload,

    output reg          price_wr_en,
    output reg  [2:0]   price_wr_addr,
    output reg  [15:0]  price_wr_data,

    output reg          stock_wr_en,
    output reg  [2:0]   stock_wr_addr,
    output reg  [15:0]  stock_wr_data,

    output reg          token_cancel_req,
    output reg  [23:0]  token_cancel_id,

    output reg          token_bulk_cancel_req,   

    output reg          auth_ok
);

    reg [PW_W-1:0] pw_store;
    reg pw_match;

    always @(posedge clk) begin
        if (!rst_n) begin
            pw_store <= 32'h0000_0000;
            auth_ok  <= 0;
            pw_match <= 0;

            price_wr_en <= 0;
            stock_wr_en <= 0;

            token_cancel_req <= 0;
            token_bulk_cancel_req <= 0;
        end
        else begin

            if (admin_pw_valid) begin // admin has asked the fsm to check the password -> compare admin_pw with pw_store
                pw_match <= (admin_pw == pw_store);
                auth_ok  <= (admin_pw == pw_store);
            end

            price_wr_en <= 0;
            stock_wr_en <= 0;
            token_cancel_req <= 0;
            token_bulk_cancel_req <= 0;

            if (admin_cmd_valid && auth_ok) begin // admin_cmd_valid is used to indicate that the admin command on the bus is valid and ready to be executed.
                case (admin_cmd)

                    4'h1: begin 
                        price_wr_addr <= admin_payload[2:0];
                        price_wr_data <= admin_payload[18:3];
                        price_wr_en   <= 1'b1;
                    end

                    4'h2: begin
                        stock_wr_addr <= admin_payload[2:0];
                        stock_wr_data <= admin_payload[18:3];
                        stock_wr_en   <= 1'b1;
                    end

                    // single cancel
                    4'h3: begin
                        token_cancel_id  <= admin_payload[11:0];
                        token_cancel_req <= 1'b1;
                    end

                    // change password
                    4'h4: begin
                        pw_store <= admin_payload[31:0];
                    end

                    // NEW: bulk delete
                    4'h5: begin
                        token_bulk_cancel_req <= 1'b1; // this goes to token manager to trigger bulk cancellation of all tokens
                    end

                endcase
            end
        end
    end
endmodule

`timescale 1ns/1ps

// ---------------------------------------------------------------------------
// order_buffer
// ---------------------------------------------------------------------------
module order_buffer #(
    parameter MAX_LINES = 7,
    parameter ITEM_ID_W = 3,
    parameter QTY_W     = 8
)(
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    append_valid,
    input  wire [ITEM_ID_W-1:0]    append_item,
    input  wire [QTY_W-1:0]        append_qty,
    input  wire                    clear,
    output wire                    full,
    output reg  [2:0]              len,

    input  wire [2:0]              read_index,
    output reg  [ITEM_ID_W-1:0]    read_item,
    output reg  [QTY_W-1:0]        read_qty
);
    reg [ITEM_ID_W-1:0] item_mem [0:MAX_LINES-1]; // reg [2:0] item_mem [0:6] 
    reg [QTY_W-1:0]     qty_mem  [0:MAX_LINES-1]; // reg [7:0] qty_mem [0:6]

    integer i;
    always @(posedge clk) begin
        if (!rst_n) begin
            len <= 0;
            for (i=0;i<MAX_LINES;i=i+1) begin
                item_mem[i] <= {ITEM_ID_W{1'b0}}; // item_mem[i] <= 3'b000
                qty_mem[i]  <= {QTY_W{1'b0}};  // qty_mem[i] <= 8'b00000000
            end
        end else begin
            if (clear) begin
                len <= 0;
                for (i=0;i<MAX_LINES;i=i+1) begin
                    item_mem[i] <= {ITEM_ID_W{1'b0}};
                    qty_mem[i]  <= {QTY_W{1'b0}};
                end
            end else if (append_valid && (len < MAX_LINES)) begin
                item_mem[len] <= append_item;
                qty_mem[len]  <= append_qty;
                len <= len + 1'b1;
            end
        end
    end

    always @(*) begin
        read_item = item_mem[read_index];
        read_qty  = qty_mem[read_index];
    end

    assign full = (len == MAX_LINES);
endmodule

`timescale 1ns/1ps

// ---------------------------------------------------------------------------
// price_table  (sync read)
// ---------------------------------------------------------------------------
module price_table #(
    parameter ITEM_COUNT = 7,
    parameter ADDR_W = 3,
    parameter DATA_W = 16
)(
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire [ADDR_W-1:0]    rd_addr,
    output reg  [DATA_W-1:0]    rd_data,
    input  wire                 wr_en,
    input  wire [ADDR_W-1:0]    wr_addr,
    input  wire [DATA_W-1:0]    wr_data
);
    reg [DATA_W-1:0] mem [0:ITEM_COUNT-1];
    integer i;
    always @(posedge clk) begin
        if (!rst_n) begin  // reset all prices to 0
            for (i=0;i<ITEM_COUNT;i=i+1) mem[i] <= {DATA_W{1'b0}};
            rd_data <= {DATA_W{1'b0}};
        end else begin // synchronous read/write
            rd_data <= mem[rd_addr];
            if (wr_en) mem[wr_addr] <= wr_data;
        end
    end
endmodule

`timescale 1ns/1ps

// ---------------------------------------------------------------------------
// stock_ram  (sync read) -> here sync read means that the data is only available on the next clock cycle after providing the address
// ---------------------------------------------------------------------------
module stock_ram #(
    parameter ITEM_COUNT = 7, // default value of 7 items, can be overridden when instantiating
    parameter ADDR_W = 3,
    parameter DATA_W = 16
)(
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire [ADDR_W-1:0]    rd_addr,
    output reg  [DATA_W-1:0]    rd_data,
    input  wire                 wr_en,
    input  wire [ADDR_W-1:0]    wr_addr,
    input  wire [DATA_W-1:0]    wr_data
);
    reg [DATA_W-1:0] mem [0:ITEM_COUNT-1]; // reg[15:0] mem[0:6]  => 7 items with 16-bit stock count each
    integer i;
    always @(posedge clk) begin
        if (!rst_n) begin
            for (i=0;i<ITEM_COUNT;i=i+1) mem[i] <= {DATA_W{1'b0}}; // initialize all stock counts to 0 on reset
            rd_data <= {DATA_W{1'b0}}; // also reset the output data to 0
        end else begin
            rd_data <= mem[rd_addr]; 
            if (wr_en) mem[wr_addr] <= wr_data;
        end
    end
endmodule

module token_manager #(
    parameter TOKEN_W = 12,
    parameter DEPTH = 4096
)(
    input  wire                 clk,
    input  wire                 rst_n,

    input  wire                 issue_req,
    input  wire [31:0]          meta_in,
    output reg                  issued_valid,
    output reg  [TOKEN_W-1:0]   token_id,

    input  wire                 cancel_req,
    input  wire [TOKEN_W-1:0]   cancel_id,

    input  wire                 bulk_cancel_req,  

    output reg  [1:0]           token_status,
    output reg                  overflow_err
);

    reg [TOKEN_W-1:0] counter;  // reg [11:0] counter -> can count up to 4096 tokens -> which is exactly enough for 4096 depth

    // token storage
    reg valid_mem [0:DEPTH-1]; // array of 4096 bits to track validity of each token ID 

    integer i;

    always @(posedge clk) begin
        if (!rst_n) begin
            counter       <= 0;
            issued_valid  <= 0;
            token_id      <= 0;
            overflow_err  <= 0;
            token_status  <= 0;

            for (i=0;i<DEPTH;i=i+1)
                valid_mem[i] <= 1'b0;
        end
        else begin
            issued_valid <= 0;

            // ISSUE TOKEN
            if (issue_req) begin
                if (counter >= DEPTH) begin
                    overflow_err <= 1'b1;
                end
                else begin
                    token_id <= counter;
                    issued_valid <= 1'b1; // boolean to indicate a new token is issued
                    valid_mem[counter] <= 1'b1; // valid_mem[token_id] <= 1'b1; mark this token ID as valid
                    counter <= counter + 1'b1; // increment counter for next token ID
                    token_status <= 2'b01;
                // 2'b00	Idle / no token
                // 2'b01	Token issued
                // 2'b10	Token served
                // 2'b11	Token cancelled
                end
            end

            // SINGLE CANCEL
            if (cancel_req) begin
                if (cancel_id < DEPTH && valid_mem[cancel_id]) begin
                    valid_mem[cancel_id] <= 1'b0;
                    token_status <= 2'b11;
                end
            end

            // BULK CANCEL
            if (bulk_cancel_req) begin 
                for (i=0;i<DEPTH;i=i+1)
                    valid_mem[i] <= 1'b0;

                token_status <= 2'b11;
            end
        end
    end

endmodule

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

