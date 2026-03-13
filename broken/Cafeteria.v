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

