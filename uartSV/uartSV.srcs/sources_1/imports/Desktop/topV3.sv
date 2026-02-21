`timescale 1ns / 1ps

module FPGACacheSystem (
    input  logic        clk,       // Main Board Clock (e.g., 100MHz)
    input  logic        reset,     // Reset Button (Active High)
    input  logic        uart_rx,   // UART RX Pin
    output logic        uart_tx,   // UART TX Pin
    output logic [3:0]  led        // Status LEDs
);

    // ==========================================
    // 1. Clock Generation
    // ==========================================
    logic sys_clk;
    
    // Slow down clock for reliable UART and logic stepping
    clkdiv #(.timer1limit(50)) clk_gen (
        .clk(clk),
        .reset(reset),
        .outclk(sys_clk)
    );

    // ==========================================
    // 2. Internal Signals
    // ==========================================
    
    // UART Signals
    logic        rx_dv;
    logic [31:0] rx_word;
    logic        tx_dv;
    logic [31:0] tx_word;
    logic        tx_active;
    logic        tx_done;

    // Cache <-> CPU (FSM) Interface
    logic [17:0] cpu_addr;
    logic [31:0] cpu_wrData;
    logic [3:0]  cpu_wrMask;
    logic        cpu_wrEn;
    logic        cpu_reqValid;
    logic [31:0] cpu_rdData;
    logic        cpu_respValid;
    logic        cpu_stall;

    // Cache <-> Memory Controller Interface
    logic [17:0] mem_addr;
    logic        mem_rdEn;      // Read Enable (Refill)
    logic [31:0] mem_data;      // Read Data
    logic        mem_valid;     // Read Data Valid
    logic        mem_ready;     // Memory Ready
    logic        mem_wrEn;      // Write Enable (Write-Through)
    logic [31:0] mem_wrData;    // Write Data

    // Backdoor (Direct BRAM) Interface
    logic [15:0] ext_addr;
    logic [31:0] ext_wdata;
    logic        ext_wen;

    // LED Debugging:
    // LED 3: CPU Stall (High during Miss/Refill)
    // LED 2: Memory Write Happening (Write-Through)
    // LED 1: Backdoor Write Happening
    // LED 0: UART RX Activity
    assign led = {cpu_stall, mem_wrEn, ext_wen, rx_dv};

    // ==========================================
    // 3. Module Instantiations
    // ==========================================

    // UART Receiver
    receiver #(.CLKS_PER_BIT(11)) uart_rx_inst (
        .i_Clock(sys_clk), 
        .i_Rx_Serial(uart_rx), 
        .o_Rx_DV(rx_dv), 
        .o_Rx_Word(rx_word)
    );

    // UART Transmitter
    transmitter #(.CLKS_PER_BIT(11)) uart_tx_inst (
        .i_Clock(sys_clk), 
        .i_Tx_DV(tx_dv), 
        .i_Tx_Word(tx_word), 
        .o_Tx_Active(tx_active), 
        .o_Tx_Serial(uart_tx), 
        .o_Tx_Done(tx_done)
    );

    // The Cache Module (Chisel Generated)
    // Supports Write-Through via io_mem_wrEn
    FourWaySetAssociativeCache cache_inst (
        .clock(sys_clk),
        .reset(reset),
        
        // CPU Side (Connected to our FSM)
        .io_cpu_addr(cpu_addr),
        .io_cpu_wrData(cpu_wrData),
        .io_cpu_wrMask(cpu_wrMask),
        .io_cpu_wrEn(cpu_wrEn),
        .io_cpu_reqValid(cpu_reqValid),
        .io_cpu_rdData(cpu_rdData),
        .io_cpu_respValid(cpu_respValid),
        .io_cpu_stall(cpu_stall),

        // Memory Side (Connected to Memory Controller)
        .io_mem_addr(mem_addr),
        .io_mem_rdEn(mem_rdEn),
        .io_mem_data(mem_data),
        .io_mem_valid(mem_valid),
        .io_mem_ready(mem_ready),
        .io_mem_wrEn(mem_wrEn),       // Write-Through Signal
        .io_mem_wrData(mem_wrData),   // Write-Through Data
        
        .io_invalidate(1'b0)
    );

    // The Memory Controller (Interface to Block RAM)
    MemoryController mem_ctrl_inst (
        .clk(sys_clk),
        .reset(reset),
        
        // Cache Interface
        .io_mem_addr(mem_addr),
        .io_mem_rdEn(mem_rdEn),
        .io_mem_data(mem_data),
        .io_mem_valid(mem_valid),
        .io_mem_ready(mem_ready),
        .io_mem_wrEn(mem_wrEn),       // Write-Through Signal
        .io_mem_wrData(mem_wrData),   // Write-Through Data
        
        // Backdoor Interface
        .ext_addr(ext_addr),
        .ext_wdata(ext_wdata),
        .ext_wen(ext_wen)
    );

    // ==========================================
    // 4. UART Control FSM (The "CPU")
    // ==========================================
    typedef enum logic [3:0] {
        IDLE,             // 0: Waiting for UART command
        RX_GET_WR_DATA,   // 1: Waiting for Data word (Write)
        RX_GET_WR_MASK,   // 2: Waiting for Mask (Write)
        DO_WRITE_REQ,     // 3: EXECUTING WRITE (Wait for Hit/Miss Resolution)
        RX_GET_RAM_DATA,  // 4: Backdoor Data
        WAIT_FOR_CACHE,   // 5: Executing Read
        SEND_RESPONSE     // 6: Sending Read Result
    } state_t;

    state_t state = IDLE;
    
    // Latches to store multi-part UART commands
    logic [17:0] latched_addr = 0;
    logic [31:0] latched_data = 0;

    // Protocol Constants
    localparam [3:0] CMD_READ_CACHE  = 4'h1; 
    localparam [3:0] CMD_WRITE_CACHE = 4'h2; 
    localparam [3:0] CMD_WRITE_RAM   = 4'h3; 

    always_ff @(posedge sys_clk) begin
        if (reset) begin
            state <= IDLE;
            cpu_reqValid <= 0;
            cpu_wrEn <= 0;
            ext_wen <= 0;
            tx_dv <= 0;
        end else begin
            
            // Auto-clear pulse signals
            ext_wen <= 0; 
            tx_dv   <= 0;

            case (state)
                // ------------------------------------------------
                // IDLE: Parse UART Opcode
                // ------------------------------------------------
                IDLE: begin
                    // SAFETY: Only clear request signals if the Cache is NOT stalled.
                    // If we clear them while stalled, we lose the request.
                    if (!cpu_stall) begin
                        cpu_reqValid <= 0;
                        cpu_wrEn <= 0; 
                    end

                    if (rx_dv) begin
                        case (rx_word[31:28])
                            // OP 1: READ CACHE
                            CMD_READ_CACHE: begin
                                cpu_addr <= rx_word[17:0];
                                cpu_wrEn <= 0;       // Read Operation
                                cpu_reqValid <= 1;   // Start Request
                                state <= WAIT_FOR_CACHE;
                            end

                            // OP 2: WRITE CACHE
                            CMD_WRITE_CACHE: begin
                                latched_addr <= rx_word[17:0];
                                state <= RX_GET_WR_DATA;
                            end

                            // OP 3: WRITE RAM (Backdoor)
                            CMD_WRITE_RAM: begin
                                latched_addr <= rx_word[17:0];
                                state <= RX_GET_RAM_DATA;
                            end
                        endcase
                    end
                end

                // ------------------------------------------------
                // READ OPERATION (Handles Miss Automatically)
                // ------------------------------------------------
                WAIT_FOR_CACHE: begin
                    // Keep request high.
                    // If Miss: cpu_stall goes High. We stay here.
                    // If Hit (or Miss Resolved): cpu_respValid goes High.
                    cpu_reqValid <= 1; 

                    if (cpu_respValid) begin
                        latched_data <= cpu_rdData;
                        cpu_reqValid <= 0;
                        state <= SEND_RESPONSE;
                    end
                end

                SEND_RESPONSE: begin
                    if (!tx_active) begin
                        tx_word <= latched_data;
                        tx_dv <= 1;
                        state <= IDLE;
                    end
                end

                // ------------------------------------------------
                // WRITE OPERATION (Step 1 & 2: Get Payload)
                // ------------------------------------------------
                RX_GET_WR_DATA: begin
                    if (rx_dv) begin
                        latched_data <= rx_word;
                        state <= RX_GET_WR_MASK;
                    end
                end

                RX_GET_WR_MASK: begin
                    if (rx_dv) begin
                        cpu_wrMask <= rx_word[3:0];
                        state <= DO_WRITE_REQ; // Go to Execution State
                    end
                end

                // ------------------------------------------------
                // WRITE EXECUTION (Handles Write Miss)
                // ------------------------------------------------
                DO_WRITE_REQ: begin
                    // 1. Assert all Write Signals
                    cpu_addr     <= latched_addr;
                    cpu_wrData   <= latched_data;
                    cpu_wrEn     <= 1;
                    cpu_reqValid <= 1;

                    // 2. WAIT FOR STALL TO CLEAR
                    // Scenario A (Hit): 
                    //    cpu_stall is 0. We enter logic immediately.
                    //    State moves to IDLE. Write is Done.
                    //
                    // Scenario B (Miss):
                    //    Cache sees address is missing. Raises cpu_stall = 1.
                    //    This logic block sees (!cpu_stall) is FALSE.
                    //    We STAY in DO_WRITE_REQ. Signals remain High (1).
                    //    Cache fetches data from MemoryController... (takes 50+ cycles)
                    //    Refill Done -> cpu_stall becomes 0.
                    //    We see (!cpu_stall) is TRUE.
                    //    State moves to IDLE. Write is Done.
                    
                    if (!cpu_stall) begin
                        state <= IDLE;
                    end
                end

                // ------------------------------------------------
                // BACKDOOR RAM WRITE
                // ------------------------------------------------
                RX_GET_RAM_DATA: begin
                    if (rx_dv) begin
                        ext_addr <= latched_addr[15:0];
                        ext_wdata <= rx_word;
                        ext_wen <= 1; 
                        state <= IDLE;
                    end
                end

            endcase
        end
    end

endmodule