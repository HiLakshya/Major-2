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