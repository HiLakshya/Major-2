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