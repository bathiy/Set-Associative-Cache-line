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
    
    logic        rx_dv;
    logic [31:0] rx_word;
    logic        tx_dv;
    logic [31:0] tx_word;
    logic        tx_active;
    logic        tx_done;

    logic [17:0] cpu_addr;
    logic [31:0] cpu_wrData;
    logic [3:0]  cpu_wrMask;
    logic        cpu_wrEn;
    logic        cpu_reqValid;
    logic [31:0] cpu_rdData;
    logic        cpu_respValid;
    logic        cpu_stall;

    logic [17:0] mem_addr;
    logic        mem_rdEn;
    logic [31:0] mem_data;
    logic        mem_valid;
    logic        mem_ready;
    logic        mem_wrEn;
    logic [31:0] mem_wrData;

    logic [15:0] ext_addr;
    logic [31:0] ext_wdata;
    logic        ext_wen;

    assign led = {cpu_stall, cpu_respValid, ext_wen, rx_dv};

    // ==========================================
    // 3. Module Instantiations
    // ==========================================

    receiver #(.CLKS_PER_BIT(11)) uart_rx_inst (
        .i_Clock(sys_clk), 
        .i_Rx_Serial(uart_rx), 
        .o_Rx_DV(rx_dv), 
        .o_Rx_Word(rx_word)
    );

    transmitter #(.CLKS_PER_BIT(11)) uart_tx_inst (
        .i_Clock(sys_clk), 
        .i_Tx_DV(tx_dv), 
        .i_Tx_Word(tx_word), 
        .o_Tx_Active(tx_active), 
        .o_Tx_Serial(uart_tx), 
        .o_Tx_Done(tx_done)
    );

    FourWaySetAssociativeCache cache_inst (
        .clock(sys_clk),
        .reset(reset),
        .io_cpu_addr(cpu_addr),
        .io_cpu_wrData(cpu_wrData),
        .io_cpu_wrMask(cpu_wrMask),
        .io_cpu_wrEn(cpu_wrEn),
        .io_cpu_reqValid(cpu_reqValid),
        .io_cpu_rdData(cpu_rdData),
        .io_cpu_respValid(cpu_respValid),
        .io_cpu_stall(cpu_stall),
        .io_mem_addr(mem_addr),
        .io_mem_rdEn(mem_rdEn),
        .io_mem_data(mem_data),
        .io_mem_valid(mem_valid),
        .io_mem_ready(mem_ready),
        .io_mem_wrEn(mem_wrEn),
        .io_mem_wrData(mem_wrData),
        .io_invalidate(1'b0)
    );

    MemoryController mem_ctrl_inst (
        .clk(sys_clk),
        .reset(reset),
        .io_mem_addr(mem_addr),
        .io_mem_rdEn(mem_rdEn),
        .io_mem_data(mem_data),
        .io_mem_valid(mem_valid),
        .io_mem_ready(mem_ready),
        .io_mem_wrEn(mem_wrEn),
        .io_mem_wrData(mem_wrData),
        .ext_addr(ext_addr),
        .ext_wdata(ext_wdata),
        .ext_wen(ext_wen)
    );

    // ==========================================
    // 4. UART Control FSM (The "CPU")
    // ==========================================
    typedef enum logic [3:0] {
        IDLE,
        RX_GET_WR_DATA,
        RX_GET_WR_MASK,
        DO_WRITE_REQ,    // <--- NEW STATE to hold the write signal
        RX_GET_RAM_DATA,
        WAIT_FOR_CACHE, 
        SEND_RESPONSE   
    } state_t;

    state_t state = IDLE;
    
    logic [17:0] latched_addr = 0;
    logic [31:0] latched_data = 0;

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
            
            ext_wen <= 0; 
            tx_dv   <= 0;

            case (state)
                IDLE: begin
                    // Only drop the request if the cache is NOT stalling.
                    // This clears the signals after the transaction is accepted.
                    if (!cpu_stall) begin
                        cpu_reqValid <= 0;
                        cpu_wrEn <= 0; 
                    end

                    if (rx_dv) begin
                        case (rx_word[31:28])
                            CMD_READ_CACHE: begin
                                cpu_addr <= rx_word[17:0];
                                cpu_wrEn <= 0;
                                cpu_reqValid <= 1;
                                state <= WAIT_FOR_CACHE;
                            end

                            CMD_WRITE_CACHE: begin
                                latched_addr <= rx_word[17:0];
                                state <= RX_GET_WR_DATA;
                            end

                            CMD_WRITE_RAM: begin
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
                    cpu_reqValid <= 1; // Hold Request High

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
                        // Latch the mask
                        cpu_wrMask <= rx_word[3:0];
                        // Transition to EXECUTE state
                        state <= DO_WRITE_REQ;
                    end
                end

                // --- NEW STATE: HOLD SIGNAL UNTIL NO STALL ---
                DO_WRITE_REQ: begin
                    // Apply signals
                    cpu_addr     <= latched_addr;
                    cpu_wrData   <= latched_data;
                    cpu_wrEn     <= 1;
                    cpu_reqValid <= 1;

                    // Only leave this state if Cache is Ready (Not Stalled)
                    if (!cpu_stall) begin
                        state <= IDLE;
                        // Signals will be cleared in IDLE state logic next cycle
                    end
                end

                // ------------------------------------------------
                // RAM LOAD LOGIC (Backdoor)
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