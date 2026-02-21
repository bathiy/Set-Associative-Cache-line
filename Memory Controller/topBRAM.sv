`timescale 1ns / 1ps

module MemoryController (

    input  logic        clk,
    input  logic        reset,

    // --------------------------------------------------------
    // 1. Interface to FourWaySetAssociativeCache
    // --------------------------------------------------------
    // The cache uses these signals to ask for a refill
    input  logic [17:0] io_mem_addr,   // 18-bit Word Address (from Cache)
    input  logic        io_mem_rdEn,   // Trigger (High when Cache Misses)
    output logic [31:0] io_mem_data,   // The data returning to Cache
    output logic        io_mem_valid,  // Pulsed high for each valid word
    output logic        io_mem_ready,  // High to acknowledge the request

    // --------------------------------------------------------
    // 2. External Write Interface (Backdoor)
    // --------------------------------------------------------
    // Since the Cache interface provided is Read-Only (Refill),
    // you need this port to write initial data into the RAM 
    // (e.g., from your UART module).
    input  logic [14:0] ext_addr,      // 16-bit Address for 64K depth
    input  logic [31:0] ext_wdata,     // Data to write
    input  logic        ext_wen        // Write Enable
    
);

    // =========================================================
    // Internal Signals
    // =========================================================
    // BRAM Interface Signals
    logic [14:0] bram_addr;
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
    // This matches the VHDL Entity port map you provided
    blk_mem_gen_1 my_bram (
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
        end else begin
            
            // Default Low signals
            io_mem_ready <= 0;
            io_mem_valid <= 0;
            bram_wea     <= 0;

            // -------------------------------------------------
            // Priority 1: External Write (Loading Data)
            // -------------------------------------------------
            if (ext_wen) begin
                bram_addr <= ext_addr;
                bram_dina <= ext_wdata;
                bram_wea  <= 1'b1;
                // Note: If a cache refill was active, this might corrupt it.
                // Usually, you only load memory before starting the CPU.
            end 
            // -------------------------------------------------
            // Priority 2: Cache Controller FSM
            // -------------------------------------------------
            else begin
 case (state)
                IDLE: begin
                    if (io_mem_rdEn) begin
                        io_mem_ready <= 1; 
                        
                        // FIX 1: ADDRESS MASKING
                        // Force lower 3 bits to 0 so 0x10 and 0x11 read the same block
                        base_addr    <= {io_mem_addr[17:3], 3'b000};
                        bram_addr    <= {io_mem_addr[14:3], 3'b000}; 
                        
                        state        <= PREPARE_BURST;
                    end
                end

                PREPARE_BURST: begin
                    // Cycle 1: BRAM is processing Addr 0.
                    // We apply Addr 1.
                    burst_counter <= 0;
                    bram_addr     <= base_addr[14:0] + 15'd1;
                    
                    // FIX 2: GO TO WAIT STATE INSTEAD OF STREAMING
                    state         <= PREPARE_WAIT;
                end

                PREPARE_WAIT: begin  // <--- NEW STATE LOGIC
                    // Cycle 2: Wait for BRAM pipeline.
                    // Setup Addr 2 so it is ready for the first streaming cycle
                    bram_addr     <= base_addr[14:0] + 15'd2;
                    state         <= STREAMING;
                end

                STREAMING: begin
                    // Cycle 3: Data 0 is finally ready. Capture it.
                    io_mem_valid <= 1;
                    io_mem_data  <= bram_douta;

                    // Address Logic:
                    // We are currently capturing Data[cnt].
                    // We need to provide Address[cnt + 3] (accounting for the 2-cycle pipeline + next)
                    // Logic: Base + Count + 1 (current) + 2 (pipeline lookahead)
                    bram_addr <= base_addr[14:0] + {12'b0, burst_counter} + 15'd3; 

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