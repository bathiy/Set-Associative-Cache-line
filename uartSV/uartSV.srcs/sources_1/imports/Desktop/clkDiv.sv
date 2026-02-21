`timescale 1ns / 1ps

module clkdiv(
    input  logic clk,
    input  logic reset,
    output logic outclk
    );

    parameter timer1limit = 50; // Threshold for toggling (e.g., 50 ticks)

    logic [31:0] timer1count = 0;
    logic        state = 1'b1;

    // Use always_ff for sequential logic with asynchronous reset
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            timer1count <= 0;
            state       <= 1'b1;
        end else begin
            if (timer1count == timer1limit) begin
                state       <= ~state;
                timer1count <= 0;
            end else begin
                // Converted blocking (=) to non-blocking (<=) for correct SV sequential behavior
                timer1count <= timer1count + 1;
            end
        end
    end
    
    assign outclk = state;

endmodule