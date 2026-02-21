`timescale 1ns / 1ps

module transmitter #(
    parameter CLKS_PER_BIT = 11
)(
    input  logic        i_Clock,
    input  logic        i_Tx_DV,       // pulse to send 32-bit word
    input  logic [31:0] i_Tx_Word,
    output logic        o_Tx_Active,
    output logic        o_Tx_Serial,
    output logic        o_Tx_Done
);

    // FSM states
    typedef enum logic [2:0] {
        s_IDLE         = 3'b000,
        s_TX_START_BIT = 3'b001,
        s_TX_DATA_BITS = 3'b010,
        s_TX_STOP_BIT  = 3'b011,
        s_NEXT_BYTE    = 3'b100
    } state_t;

    state_t r_SM_Main     = s_IDLE;
    
    logic [7:0]  r_Clock_Count = 0;
    logic [2:0]  r_Bit_Index   = 0;
    logic [1:0]  r_Byte_Index  = 0;
    logic [7:0]  r_Tx_Byte     = 0;
    logic [31:0] r_Tx_Word     = 0;
    logic        r_Tx_Active   = 0;
    logic        r_Tx_Done     = 0;

    // =====================================================
    // UART TX FSM
    // =====================================================
    always_ff @(posedge i_Clock) begin
        r_Tx_Done <= 1'b0; // default

        case (r_SM_Main)
            // -------------------------------
            // IDLE
            // -------------------------------
            s_IDLE: begin
                o_Tx_Serial   <= 1'b1;
                r_Tx_Active   <= 1'b0;
                r_Clock_Count <= 0;
                r_Bit_Index   <= 0;
                r_Byte_Index  <= 0;

                if (i_Tx_DV) begin
                    r_Tx_Word   <= i_Tx_Word;
                    r_Tx_Byte   <= i_Tx_Word[7:0];
                    r_Tx_Active <= 1'b1;
                    r_SM_Main   <= s_TX_START_BIT;
                end
            end

            // -------------------------------
            // START BIT
            // -------------------------------
            s_TX_START_BIT: begin
                o_Tx_Serial <= 1'b0;
                if (r_Clock_Count < CLKS_PER_BIT-1) begin
                    r_Clock_Count <= r_Clock_Count + 1;
                end else begin
                    r_Clock_Count <= 0;
                    r_SM_Main     <= s_TX_DATA_BITS;
                end
            end

            // -------------------------------
            // DATA BITS
            // -------------------------------
            s_TX_DATA_BITS: begin
                o_Tx_Serial <= r_Tx_Byte[r_Bit_Index];
                if (r_Clock_Count < CLKS_PER_BIT-1) begin
                    r_Clock_Count <= r_Clock_Count + 1;
                end else begin
                    r_Clock_Count <= 0;
                    if (r_Bit_Index < 7) begin
                        r_Bit_Index <= r_Bit_Index + 1;
                    end else begin
                        r_Bit_Index <= 0;
                        r_SM_Main   <= s_TX_STOP_BIT;
                    end
                end
            end

            // -------------------------------
            // STOP BIT
            // -------------------------------
            s_TX_STOP_BIT: begin
                o_Tx_Serial <= 1'b1;
                if (r_Clock_Count < CLKS_PER_BIT-1) begin
                    r_Clock_Count <= r_Clock_Count + 1;
                end else begin
                    r_Clock_Count <= 0;
                    r_SM_Main     <= s_NEXT_BYTE;
                end
            end

            // -------------------------------
            // NEXT BYTE / DONE
            // -------------------------------
            s_NEXT_BYTE: begin
                if (r_Byte_Index < 3) begin
                    r_Byte_Index <= r_Byte_Index + 1;
                    // Using indexed part-select for variable slice
                    r_Tx_Byte    <= r_Tx_Word[(r_Byte_Index+1)*8 +: 8];
                    r_SM_Main    <= s_TX_START_BIT;
                end else begin
                    r_Tx_Active <= 1'b0;
                    r_Tx_Done   <= 1'b1; // Full 32-bit word sent
                    r_SM_Main   <= s_IDLE;
                end
            end

            default: r_SM_Main <= s_IDLE;
        endcase
    end

    assign o_Tx_Active = r_Tx_Active;
    assign o_Tx_Done   = r_Tx_Done;

endmodule