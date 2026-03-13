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

