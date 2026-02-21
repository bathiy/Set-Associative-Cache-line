/* `timescale 1ns / 1ps

module MemoryController (

    input  logic        clk,
    input  logic        reset,

    // --------------------------------------------------------
    // 1. Interface to FourWaySetAssociativeCache
    // --------------------------------------------------------
    input  logic [17:0] io_mem_addr,   // 18-bit Word Address (from Cache)
    input  logic        io_mem_rdEn,   // Trigger (High when Cache Misses/Refill)
    
    // NEW: Write Interface from Cache (Write-Through)
    input  logic        io_mem_wrEn,   // Trigger (High when CPU writes to Cache)
    input  logic [31:0] io_mem_wrData, // Data to write to memory
    
    output logic [31:0] io_mem_data,   // The data returning to Cache (Read)
    output logic        io_mem_valid,  // Pulsed high for each valid word
    output logic        io_mem_ready,  // High to acknowledge the request

    // --------------------------------------------------------
    // 2. External Write Interface (Backdoor / UART)
    // --------------------------------------------------------
    input  logic [15:0] ext_addr,      // 16-bit Address for 64K depth
    input  logic [31:0] ext_wdata,     // Data to write
    input  logic        ext_wen        // Write Enable
    
);

    // =========================================================
    // Internal Signals
    // =========================================================
    // BRAM Interface Signals
    logic [15:0] bram_addr;
    logic [31:0] bram_dina;
    logic [0:0]  bram_wea;     // Vector for VHDL compatibility
    logic [31:0] bram_douta;

    // State Machine
    typedef enum logic [1:0] { 
        IDLE, 
        PREPARE_BURST, 
        PREPARE_WAIT,
        STREAMING 
    } state_t;

    state_t state = IDLE;

    // Registers
    logic [2:0]  burst_counter; // 0 to 7
    logic [17:0] base_addr;     // Latched address from cache

    // =========================================================
    // BRAM Instantiation (blk_mem_gen_0)
    // =========================================================
    blk_mem_gen_0 my_bram (
        .clka   (clk),
        .ena    (1'b1),        // Always Enable
        .wea    (bram_wea),    // Write Enable (Vector)
        .addra  (bram_addr),   // 16-bit Address
        .dina   (bram_dina),   // 32-bit Data In
        .douta  (bram_douta)   // 32-bit Data Out
    );

    // =========================================================
    // Memory Controller Logic
    // =========================================================
    always_ff @(posedge clk) begin
        if (reset) begin
            state         <= IDLE;
            io_mem_ready  <= 0;
            io_mem_valid  <= 0;
            burst_counter <= 0;
            bram_wea      <= 0;
            bram_addr     <= 0;
            bram_dina     <= 0;
        end else begin
            
            // Default Low signals
            io_mem_ready <= 0;
            io_mem_valid <= 0;
            bram_wea     <= 0;

            // -------------------------------------------------
            // Priority 1: Cache Write (Write-Through)
            // -------------------------------------------------
            if (io_mem_wrEn) begin
                // Direct Write to BRAM
                // Convert 18-bit Cache Addr to 16-bit BRAM Addr
                bram_addr <= io_mem_addr[15:0]; 
                bram_dina <= io_mem_wrData;
                bram_wea  <= 1'b1;
            end 
            // -------------------------------------------------
            // Priority 2: External Write (UART Backdoor)
            // -------------------------------------------------
            else if (ext_wen) begin
                bram_addr <= ext_addr;
                bram_dina <= ext_wdata;
                bram_wea  <= 1'b1;
            end 
            // -------------------------------------------------
            // Priority 3: Cache Read (Refill FSM)
            // -------------------------------------------------
            else begin
                case (state)
                    IDLE: begin
                        if (io_mem_rdEn) begin
                            io_mem_ready <= 1; 
                            
                            // ADDRESS MASKING (Align to block start)
                            base_addr    <= {io_mem_addr[17:3], 3'b000};
                            bram_addr    <= {io_mem_addr[15:3], 3'b000}; 
                            
                            state        <= PREPARE_BURST;
                        end
                    end

                    PREPARE_BURST: begin
                        // Cycle 1: Apply Addr 1
                        burst_counter <= 0;
                        bram_addr     <= base_addr[15:0] + 16'd1;
                        state         <= PREPARE_WAIT;
                    end

                    PREPARE_WAIT: begin
                        // Cycle 2: Wait for BRAM pipeline. Apply Addr 2.
                        bram_addr     <= base_addr[15:0] + 16'd2;
                        state         <= STREAMING;
                    end

                    STREAMING: begin
                        // Cycle 3+: Capture Data 0...7
                        io_mem_valid <= 1;
                        io_mem_data  <= bram_douta;

                        // Address Logic (Lookahead +3)
                        bram_addr <= base_addr[15:0] + {13'b0, burst_counter} + 16'd3; 

                        burst_counter <= burst_counter + 1;

                        if (burst_counter == 7) begin
                            state <= IDLE;
                        end
                    end
                endcase
            end
        end
    end

endmodule */
`timescale 1ns / 1ps

module MemoryController (
    input  logic        clk,
    input  logic        reset,

    // --------------------------------------------------------
    // Cache Interface
    // --------------------------------------------------------
    input  logic [17:0] io_mem_addr,   // Shared Address (Read or Write)
    input  logic        io_mem_rdEn,   // Trigger Refill (Read from BRAM)
    
    // NEW: Write-Through Interface
    input  logic        io_mem_wrEn,   // Trigger Write (Write to BRAM)
    input  logic [31:0] io_mem_wrData, // Data from Cache to BRAM
    
    output logic [31:0] io_mem_data,   // Data from BRAM to Cache
    output logic        io_mem_valid,  // Read Data Valid
    output logic        io_mem_ready,  // Ready for new request

    // --------------------------------------------------------
    // UART Backdoor Interface
    // --------------------------------------------------------
    input  logic [15:0] ext_addr,
    input  logic [31:0] ext_wdata,
    input  logic        ext_wen
);

    // BRAM Signals
    logic [15:0] bram_addr;
    logic [31:0] bram_dina;
    logic [0:0]  bram_wea;
    logic [31:0] bram_douta;

    // FSM States
    typedef enum logic [1:0] { 
        IDLE, 
        PREPARE_BURST, 
        PREPARE_WAIT,
        STREAMING 
    } state_t;

    state_t state = IDLE;

    logic [2:0]  burst_counter;
    logic [17:0] base_addr;

    // --------------------------------------------------------
    // BRAM Instantiation
    // --------------------------------------------------------
    blk_mem_gen_0 my_bram (
        .clka   (clk),
        .ena    (1'b1),
        .wea    (bram_wea),
        .addra  (bram_addr),
        .dina   (bram_dina),
        .douta  (bram_douta)
    );

    // --------------------------------------------------------
    // Controller Logic
    // --------------------------------------------------------
    always_ff @(posedge clk) begin
        if (reset) begin
            state         <= IDLE;
            io_mem_ready  <= 0;
            io_mem_valid  <= 0;
            burst_counter <= 0;
            bram_wea      <= 0;
            bram_addr     <= 0;
            bram_dina     <= 0;
        end else begin
            
            // Default Low signals
            io_mem_ready <= 0;
            io_mem_valid <= 0;
            bram_wea     <= 0;

            // -------------------------------------------------
            // Priority 1: Cache Write (Write-Through)
            // -------------------------------------------------
            if (io_mem_wrEn) begin
                bram_addr <= io_mem_addr[15:0]; 
                bram_dina <= io_mem_wrData;
                bram_wea  <= 1'b1;
            end 
            // -------------------------------------------------
            // Priority 2: UART Backdoor Write
            // -------------------------------------------------
            else if (ext_wen) begin
                bram_addr <= ext_addr;
                bram_dina <= ext_wdata;
                bram_wea  <= 1'b1;
            end 
            // -------------------------------------------------
            // Priority 3: Cache Read (Refill)
            // -------------------------------------------------
            else begin
                case (state)
                    IDLE: begin
                        if (io_mem_rdEn) begin
                            io_mem_ready <= 1; 
                            // Align address to 8-word block boundary
                            base_addr    <= {io_mem_addr[17:3], 3'b000};
                            bram_addr    <= {io_mem_addr[15:3], 3'b000}; 
                            state        <= PREPARE_BURST;
                        end
                    end

                    PREPARE_BURST: begin
                        burst_counter <= 0;
                        bram_addr     <= base_addr[15:0] + 16'd1;
                        state         <= PREPARE_WAIT;
                    end

                    PREPARE_WAIT: begin
                        bram_addr     <= base_addr[15:0] + 16'd2;
                        state         <= STREAMING;
                    end

                    STREAMING: begin
                        io_mem_valid <= 1;
                        io_mem_data  <= bram_douta;
                        // Lookahead address logic for pipeline
                        bram_addr <= base_addr[15:0] + {13'b0, burst_counter} + 16'd3; 

                        burst_counter <= burst_counter + 1;
                        if (burst_counter == 7) begin
                            state <= IDLE;
                        end
                    end
                endcase
            end
        end
    end

endmodule