`timescale 1ns / 1ps

module top_uart_rx_tx (
    input  logic       clk,        // 125 MHz
    input  logic       reset,      // active-high
    input  logic       uart_rx,    // UART RX pin
    input  logic       btn,        // push button
    output logic       uart_tx,    // UART TX pin
    output logic [3:0] led
);

    // =====================================================
    // Parameters
    // =====================================================
    localparam CLKS_PER_BIT = 11; 

    // Internal Signals
    logic        newClk;
    logic        recieved = 0;
    logic [31:0] TX_BYTE  = 32'hABCD1255;

    // =====================================================
    // Clock Divider Instance
    // =====================================================
    clkdiv nclk (
        .clk(clk),
        .reset(reset),
        .outclk(newClk)
    );

    // =====================================================
    // UART RX signals
    // =====================================================
    logic        rx_dv;
    logic [31:0] rx_byte;

    // =====================================================
    // UART TX signals
    // =====================================================
    logic        tx_dv;
    logic        tx_active;
    logic        tx_done;

    // =====================================================
    // Button synchronizer & edge detect
    // =====================================================
    logic [1:0] btn_sync;
    logic       btn_prev;

    always_ff @(posedge newClk) begin
        btn_sync <= {btn_sync[0], btn};
        btn_prev <= btn_sync[1];
    end

    wire btn_pressed = btn_sync[1] & ~btn_prev;

    // =====================================================
    // UART RECEIVER
    // =====================================================
    receiver #(
        .CLKS_PER_BIT(CLKS_PER_BIT)
    ) uart_rx_inst (
        .i_Clock    (newClk),
        .i_Rx_Serial(uart_rx),
        .o_Rx_DV    (rx_dv),
        .o_Rx_Word  (rx_byte)
    );

    // =====================================================
    // UART TRANSMITTER
    // =====================================================
    transmitter #(
        .CLKS_PER_BIT(CLKS_PER_BIT)
    ) uart_tx_inst (
        .i_Clock    (newClk),
        .i_Tx_DV    (tx_dv),
        .i_Tx_Word  (TX_BYTE),
        .o_Tx_Active(tx_active),
        .o_Tx_Serial(uart_tx),
        .o_Tx_Done  (tx_done)
    );

    // =====================================================
    // Control logic
    // =====================================================
    always_ff @(posedge newClk) begin
        if (reset) begin
            led      <= 4'b0000;
            tx_dv    <= 1'b0;
            recieved <= 0;
            TX_BYTE  <= 0;
        end else begin
            tx_dv <= 1'b0; // default

            // Show received byte and store it
            if (rx_dv) begin
                led      <= rx_byte[23:20];
                TX_BYTE  <= rx_byte;
                recieved <= 1;
            end

            // Send byte on button press
            if (btn_pressed && !tx_active && recieved) begin
                tx_dv    <= 1'b1;
                recieved <= 0;
            end
        end
    end

endmodule