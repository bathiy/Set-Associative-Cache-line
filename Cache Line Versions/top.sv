`timescale 1ns / 1ps

module FPGACacheSystem (
    input  logic        clk,       // Main Board Clock
    input  logic        reset,     // Button
    input  logic        uart_rx,   // UART RX Pin
    output logic        uart_tx,   // UART TX Pin
    output logic [3:0]  led        // Status LEDs
);

    // ==========================================
    // 1. Clock Generation
    // ==========================================
    logic sys_clk;
    
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

    // Cache CPU Interface (Driven by UART FSM)
    logic [17:0] cpu_addr;
    logic [31:0] cpu_wrData;
    logic [3:0]  cpu_wrMask;
    logic        cpu_wrEn;
    logic        cpu_reqValid;
    logic [31:0] cpu_rdData;
    logic        cpu_respValid;
    logic        cpu_stall;

    // Cache <-> Memory Controller Interface (Internal Connection)
    logic [17:0] mem_addr;
    logic        mem_rdEn;
    logic [31:0] mem_data;
    logic        mem_valid;
    logic        mem_ready;

    // Backdoor Memory Interface (Driven by UART FSM)
    logic [15:0] ext_addr;
    logic [31:0] ext_wdata;
    logic        ext_wen;

    // LED Status
    // LED 3: Cache Stall (Miss in progress)
    // LED 2: CPU Valid Response (Hit)
    // LED 1: Backdoor Write Active
    // LED 0: Heartbeat/RX
    assign led = {cpu_stall, cpu_respValid, ext_wen, rx_dv};

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

    // The Cache
    FourWaySetAssociativeCache cache_inst (
        .clock(sys_clk),
        .reset(reset),
        
        // CPU Side (Connected to FSM)
        .io_cpu_addr(cpu_addr),
        .io_cpu_wrData(cpu_wrData),
        .io_cpu_wrMask(cpu_wrMask),
        .io_cpu_wrEn(cpu_wrEn),
        .io_cpu_reqValid(cpu_reqValid),
        .io_cpu_rdData(cpu_rdData),
        .io_cpu_respValid(cpu_respValid),
        .io_cpu_stall(cpu_stall),

        // Memory Side (Connected to Controller)
        .io_mem_addr(mem_addr),
        .io_mem_rdEn(mem_rdEn),
        .io_mem_data(mem_data),
        .io_mem_valid(mem_valid),
        .io_mem_ready(mem_ready),
        
        .io_invalidate(1'b0)
    );

    // The Memory Controller (Now manages the BRAM)
    MemoryController mem_ctrl_inst (
        .clk(sys_clk),
        .reset(reset),
        
        // Connect to Cache
        .io_mem_addr(mem_addr),
        .io_mem_rdEn(mem_rdEn),
        .io_mem_data(mem_data),
        .io_mem_valid(mem_valid),
        .io_mem_ready(mem_ready),
        
        // Connect to UART FSM (for loading RAM)
        .ext_addr(ext_addr),
        .ext_wdata(ext_wdata),
        .ext_wen(ext_wen)
    );

    // ==========================================
    // 4. UART Control FSM (The "CPU")
    // ==========================================
    typedef enum logic [3:0] {
        IDLE,
        // Cache Write States
        RX_GET_WR_DATA,
        RX_GET_WR_MASK,
        // RAM Load States
        RX_GET_RAM_DATA,
        // Execution States
        WAIT_FOR_CACHE,  // Waiting for Hit or Refill
        SEND_RESPONSE    // Sending Result to UART
    } state_t;

    state_t state = IDLE;
    
    logic [17:0] latched_addr = 0;
    logic [31:0] latched_data = 0;

    // Protocol Opcodes
    localparam [3:0] CMD_READ_CACHE  = 4'h1; // 0x1...
    localparam [3:0] CMD_WRITE_CACHE = 4'h2; // 0x2...
    localparam [3:0] CMD_WRITE_RAM   = 4'h3; // 0x3... (New!)
    localparam [31:0] HDR_HIT        = 32'hAAAA_AAAA;

    always_ff @(posedge sys_clk) begin
        if (reset) begin
            state <= IDLE;
            cpu_reqValid <= 0;
            cpu_wrEn <= 0;
            ext_wen <= 0;
            tx_dv <= 0;
        end else begin
            
            // Default Signal Levels
            ext_wen <= 0; // Pulse only
            tx_dv   <= 0;

            case (state)
                // ------------------------------------------------
                // IDLE: Wait for Command
                // ------------------------------------------------
                IDLE: begin
                    // If we just finished a request, verify valid is low
                    if (!cpu_stall) cpu_reqValid <= 0;

                    if (rx_dv) begin
                        case (rx_word[31:28])
                            CMD_READ_CACHE: begin
                                // Start Read Request
                                cpu_addr <= rx_word[17:0];
                                cpu_wrEn <= 0;
                                cpu_reqValid <= 1;
                                state <= WAIT_FOR_CACHE;
                            end

                            CMD_WRITE_CACHE: begin
                                // Prepare for Write
                                latched_addr <= rx_word[17:0];
                                state <= RX_GET_WR_DATA;
                            end

                            CMD_WRITE_RAM: begin
                                // Prepare for RAM Load (Backdoor)
                                latched_addr <= rx_word[17:0];
                                state <= RX_GET_RAM_DATA;
                            end
                        endcase
                    end
                end

                // ------------------------------------------------
                // CACHE READ LOGIC
                // ------------------------------------------------
                WAIT_FOR_CACHE: begin
                    // Keep Request Valid High until we get a response.
                    // If it stalls (Miss), hardware handles refill automatically.
                    // We just wait for 'cpu_respValid' to eventually go High.
                    cpu_reqValid <= 1; 

                    if (cpu_respValid) begin
                        latched_data <= cpu_rdData;
                        cpu_reqValid <= 0; // Request satisfied
                        state <= SEND_RESPONSE;
                    end
                end

                SEND_RESPONSE: begin
                    if (!tx_active) begin
                        tx_word <= latched_data; // Send the data back
                        tx_dv <= 1;
                        state <= IDLE;
                    end
                end

                // ------------------------------------------------
                // CACHE WRITE LOGIC
                // ------------------------------------------------
                RX_GET_WR_DATA: begin
                    if (rx_dv) begin
                        latched_data <= rx_word;
                        state <= RX_GET_WR_MASK;
                    end
                end

                RX_GET_WR_MASK: begin
                    if (rx_dv) begin
                        // Execute Cache Write
                        cpu_addr <= latched_addr;
                        cpu_wrData <= latched_data;
                        cpu_wrMask <= rx_word[3:0];
                        cpu_wrEn <= 1;
                        cpu_reqValid <= 1;
                        
                        // We don't wait for response on write (Hit/Miss handled internally)
                        // Just pulse valid for a few cycles or wait for stall to be low
                        state <= IDLE; 
                    end
                end

                // ------------------------------------------------
                // RAM LOAD LOGIC (Backdoor)
                // ------------------------------------------------
                RX_GET_RAM_DATA: begin
                    if (rx_dv) begin
                        // Write directly to BRAM
                        ext_addr <= latched_addr[15:0];
                        ext_wdata <= rx_word;
                        ext_wen <= 1; // Pulse write enable
                        state <= IDLE;
                    end
                end

            endcase
        end
    end

endmodule