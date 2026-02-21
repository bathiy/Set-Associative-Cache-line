`timescale 1ns / 1ps

module receiver #(
    parameter CLKS_PER_BIT = 11
)(
    input  logic        i_Clock,
    input  logic        i_Rx_Serial,
    output logic        o_Rx_DV,
    output logic [31:0] o_Rx_Word
);

    // UART states
    typedef enum logic [2:0] {
        s_IDLE         = 3'b000,
        s_RX_START_BIT = 3'b001,
        s_RX_DATA_BITS = 3'b010,
        s_RX_STOP_BIT  = 3'b011,
        s_CLEANUP      = 3'b100
    } state_t;

    state_t r_SM_Main = s_IDLE;

    logic       r_Rx_Data_R = 1'b1;
    logic       r_Rx_Data   = 1'b1;
    logic [7:0] r_Clock_Count = 0;
    logic [2:0] r_Bit_Index   = 0;
    logic [7:0] r_Rx_Byte     = 0;
    
    // 32-bit assembly counter
    logic [1:0] byte_count = 0;

    // -------------------------------------------------
    // Double register RX input to remove metastability
    // -------------------------------------------------
    always_ff @(posedge i_Clock) begin
        r_Rx_Data_R <= i_Rx_Serial;
        r_Rx_Data   <= r_Rx_Data_R;
    end

    // -------------------------------------------------
    // UART RX FSM
    // -------------------------------------------------
    always_ff @(posedge i_Clock) begin
        o_Rx_DV <= 1'b0; // Default assignment

        case (r_SM_Main)
            s_IDLE: begin
                r_Clock_Count <= 0;
                r_Bit_Index   <= 0;
                if (r_Rx_Data == 1'b0) begin
                    r_SM_Main <= s_RX_START_BIT;
                end
            end

            s_RX_START_BIT: begin
                if (r_Clock_Count == (CLKS_PER_BIT-1)/2) begin
                    if (r_Rx_Data == 1'b0) begin
                        r_Clock_Count <= 0;
                        r_Rx_Byte     <= 8'd0;
                        r_SM_Main     <= s_RX_DATA_BITS;
                    end else begin
                        r_SM_Main <= s_IDLE;
                    end
                end else begin
                    r_Clock_Count <= r_Clock_Count + 1;
                end
            end

            s_RX_DATA_BITS: begin
                if (r_Clock_Count == CLKS_PER_BIT/2) begin
                    r_Rx_Byte[r_Bit_Index] <= r_Rx_Data; // Sample in middle
                end

                if (r_Clock_Count < CLKS_PER_BIT-1) begin
                    r_Clock_Count <= r_Clock_Count + 1;
                end else begin
                    r_Clock_Count <= 0;
                    if (r_Bit_Index < 7) begin
                        r_Bit_Index <= r_Bit_Index + 1;
                    end else begin
                        r_Bit_Index <= 0;
                        r_SM_Main   <= s_RX_STOP_BIT;
                    end
                end
            end

            s_RX_STOP_BIT: begin
                if (r_Clock_Count < CLKS_PER_BIT-1) begin
                    r_Clock_Count <= r_Clock_Count + 1;
                end else begin
                    r_Clock_Count <= 0;
                    r_SM_Main     <= s_CLEANUP;
                end
            end

            s_CLEANUP: begin
                // Store received byte into 32-bit word
                case (byte_count)
                    2'd0: o_Rx_Word[7:0]   <= r_Rx_Byte;
                    2'd1: o_Rx_Word[15:8]  <= r_Rx_Byte;
                    2'd2: o_Rx_Word[23:16] <= r_Rx_Byte;
                    2'd3: o_Rx_Word[31:24] <= r_Rx_Byte;
                endcase

                if (byte_count == 2'd3) begin
                    byte_count <= 0;
                    o_Rx_DV    <= 1'b1; // Full 32-bit word ready
                end else begin
                    byte_count <= byte_count + 1;
                end

                r_SM_Main <= s_IDLE;
            end

            default: r_SM_Main <= s_IDLE;
        endcase
    end

endmodule