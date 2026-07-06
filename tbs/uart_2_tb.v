`timescale 1ns/1ps

module uart_tb;

// =========================================================================
// Parameters
// =========================================================================
localparam integer CLK_PERIOD = 20;
localparam [15:0]  BAUD_DIV   = 16'h01B2;
localparam [31:0]  CFG_DATA   = {4'h0, 6'b010000, 6'b001001, BAUD_DIV};

localparam [31:0] ADDR_CFG = 32'h00000000;
localparam [31:0] ADDR_TX  = 32'h00000004;
localparam [31:0] ADDR_RX  = 32'h00000008;
localparam [31:0] ADDR_STA = 32'h0000000C;

localparam integer T1_COUNT = 32;
localparam integer T2_TOTAL = 6;

// =========================================================================
// Signals
// =========================================================================
reg         clk, rst_n;
reg         psel, penable, pwrite;
reg  [31:0] paddr, pwdata;
wire [31:0] prdata;
wire        pready, pslverr, tx_pin, irq;

reg  [31:0] cfg_rb, sta_rd, rx_rd;
integer     i, wait_count;
reg         last_apb_pslverr, apb_bus_busy;
integer     cur_retries;

// Test 1
reg  [7:0]  t1_rx_expect [0:T1_COUNT-1];
reg  [7:0]  t1_rx_got    [0:T1_COUNT-1];
integer     t1_tx_retries[0:T1_COUNT-1];
integer     t1_irq_rx_cnt, t1_err_cnt;

// Test 2
reg  [7:0]  t2_expect [0:T2_TOTAL-1];
reg  [7:0]  t2_got    [0:T2_TOTAL-1];
integer     t2_irq_rx_cnt, t2_err_cnt;
reg         t2_isr_do_write;
reg  [7:0]  t2_isr_write_data;
reg         t2_isr_write_done;

// ISR control
reg         isr_active, irq_held, cpu_irq_pending;
integer     test_phase;

// =========================================================================
// DUT - loopback
// =========================================================================
uart u_uart (
    .clk(clk), .rst_n(rst_n),
    .psel(psel), .penable(penable), .pwrite(pwrite),
    .paddr(paddr), .pwdata(pwdata),
    .prdata(prdata), .pready(pready), .pslverr(pslverr),
    .rx_pin(tx_pin), .tx_pin(tx_pin), .irq(irq)
);

// =========================================================================
// Clock
// =========================================================================
initial clk = 0;
always #(CLK_PERIOD/2) clk = ~clk;

// =========================================================================
// Interrupt Manager
// =========================================================================
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        cpu_irq_pending <= 0;
        irq_held        <= 0;
    end else begin
        if (irq && !isr_active && !cpu_irq_pending)
            cpu_irq_pending <= 1;
        else if (irq && isr_active)
            irq_held <= 1;
        if (!isr_active && irq_held && !cpu_irq_pending) begin
            cpu_irq_pending <= 1;
            irq_held        <= 0;
        end
        if (isr_active && cpu_irq_pending)
            cpu_irq_pending <= 0;
    end
end

// =========================================================================
// APB Write Task
// =========================================================================
task apb_write;
    input [31:0] addr;
    input [31:0] data;
    begin
        while (apb_bus_busy) @(posedge clk);
        apb_bus_busy = 1;
        @(posedge clk);
        psel=1; penable=0; pwrite=1; paddr=addr; pwdata=data;
        @(posedge clk);
        penable = 1;
        while (!pready) @(posedge clk);
        last_apb_pslverr = pslverr;
        @(posedge clk);
        psel=0; penable=0; pwrite=0;
        apb_bus_busy = 0;
    end
endtask

// =========================================================================
// APB Read Task
// =========================================================================
task apb_read;
    input  [31:0] addr;
    output [31:0] rdata;
    begin
        while (apb_bus_busy) @(posedge clk);
        apb_bus_busy = 1;
        @(posedge clk);
        psel=1; penable=0; pwrite=0; paddr=addr; pwdata=0;
        @(posedge clk);
        penable = 1;
        while (!pready) @(posedge clk);
        last_apb_pslverr = pslverr;
        if (pslverr) rdata = 32'hDEAD_BEEF;
        else         rdata = prdata;
        @(posedge clk);
        psel=0; penable=0;
        repeat(2) @(posedge clk);
        apb_bus_busy = 0;
    end
endtask

// =========================================================================
// APB Write Safe
// 写失败后等待 512~1024 随机周期再重试，永不放弃
// =========================================================================
task apb_write_safe;
    input [31:0] addr;
    input [31:0] data;
    integer wait_cyc;
    begin
        cur_retries = 0;
        begin : safe_loop
            forever begin
                apb_write(addr, data);
                if (!last_apb_pslverr) begin
                    disable safe_loop;
                end else begin
                    cur_retries = cur_retries + 1;
                    // 512 + pseudo-random 0~511 cycles
                    wait_cyc = 512 + (($time / CLK_PERIOD) % 512);
                    $display("[%0t] apb_write_safe: NACK addr=0x%08X retry=%0d wait=%0d cyc",
                             $time, addr, cur_retries, wait_cyc);
                    repeat(wait_cyc) @(posedge clk);
                end
            end
        end
    end
endtask

// =========================================================================
// ISR Block
// =========================================================================
initial begin
    isr_active      = 0;
    t1_irq_rx_cnt   = 0;
    t2_irq_rx_cnt   = 0;
    t2_isr_write_done = 0;
    for (i = 0; i < T1_COUNT; i=i+1) t1_rx_got[i] = 8'hFF;
    for (i = 0; i < T2_TOTAL; i=i+1) t2_got[i]    = 8'hFF;

    @(posedge rst_n);
    repeat(20) @(posedge clk);

    forever begin
        wait (cpu_irq_pending === 1'b1);
        @(posedge clk);
        isr_active = 1;

        if (test_phase == 1) begin
            apb_read(ADDR_RX, rx_rd);
            if (t1_irq_rx_cnt < T1_COUNT) begin
                t1_rx_got[t1_irq_rx_cnt] = rx_rd[7:0];
                $display("[%0t] T1-ISR: RX[%0d] = 0x%02X%s",
                         $time, t1_irq_rx_cnt, rx_rd[7:0],
                         last_apb_pslverr ? " [ERR]" : "");
                t1_irq_rx_cnt = t1_irq_rx_cnt + 1;
            end

        end else if (test_phase == 2) begin
            apb_read(ADDR_RX, rx_rd);
            if (t2_irq_rx_cnt < T2_TOTAL) begin
                t2_got[t2_irq_rx_cnt] = rx_rd[7:0];
                $display("[%0t] T2-ISR: RX[%0d] = 0x%02X%s",
                         $time, t2_irq_rx_cnt, rx_rd[7:0],
                         last_apb_pslverr ? " [ERR]" : "");
                t2_irq_rx_cnt = t2_irq_rx_cnt + 1;
            end
            if (t2_isr_do_write) begin
                $display("[%0t] T2-ISR: B2B WRITE 0x%02X", $time, t2_isr_write_data);
                apb_write_safe(ADDR_TX, {24'd0, t2_isr_write_data});
                t2_isr_write_done = 1;
                t2_isr_do_write   = 0;
            end
        end

        isr_active = 0;
        repeat(2) @(posedge clk);
    end
end

// =========================================================================
// Main Stimulus
// =========================================================================
initial begin
    psel=0; penable=0; pwrite=0; paddr=0; pwdata=0;
    rst_n=0;
    last_apb_pslverr=0; apb_bus_busy=0; cur_retries=0;
    test_phase=0;
    t2_isr_do_write=0; t2_isr_write_data=0; t2_isr_write_done=0;

    for (i=0; i<T1_COUNT; i=i+1) begin
        t1_rx_expect[i] = 0;
        t1_tx_retries[i] = 0;
    end
    for (i=0; i<T2_TOTAL; i=i+1) t2_expect[i] = 0;

    repeat(10) @(posedge clk);
    #20 rst_n = 1;
    repeat(5) @(posedge clk);

    // Config
    apb_write(ADDR_CFG, CFG_DATA);
    repeat(30) @(posedge clk);
    apb_read(ADDR_CFG, cfg_rb);
    if (cfg_rb == CFG_DATA)
        $display("[%0t] CFG OK: 0x%08X", $time, cfg_rb);
    else
        $display("[%0t] CFG FAIL: got 0x%08X exp 0x%08X", $time, cfg_rb, CFG_DATA);

    // =====================================================================
    // TEST 1: 32 frames
    // 前16帧背靠背快速写（填满FIFO），后16帧 write_safe 轮询
    // 写失败等 512~1024 周期重试，写成功立即发下一帧
    // =====================================================================
    $display("\n[%0t] ===== TEST 1: 32 frames (fast fill + safe poll) =====", $time);
    test_phase    = 1;
    t1_irq_rx_cnt = 0;

    for (i=0; i<T1_COUNT; i=i+1) t1_rx_expect[i] = i + 8'h01;

    // Phase A: fast back-to-back (first 16)
    $display("[%0t] T1 Phase-A: fast B2B write [0..15]", $time);
    for (i=0; i<16; i=i+1) begin
        apb_write_safe(ADDR_TX, {24'd0, t1_rx_expect[i]});
        t1_tx_retries[i] = cur_retries;
        $display("[%0t] T1-TX[%02d] = 0x%02X  retries=%0d",
                 $time, i, t1_rx_expect[i], cur_retries);
    end

    // Phase B: slow poll (remaining 16), write_safe handles backpressure
    $display("[%0t] T1 Phase-B: safe-poll write [16..31]", $time);
    for (i=16; i<T1_COUNT; i=i+1) begin
        apb_write_safe(ADDR_TX, {24'd0, t1_rx_expect[i]});
        t1_tx_retries[i] = cur_retries;
        $display("[%0t] T1-TX[%02d] = 0x%02X  retries=%0d",
                 $time, i, t1_rx_expect[i], cur_retries);
    end

    $display("[%0t] T1: all %0d frames sent, waiting RX...", $time, T1_COUNT);
    wait_count = 0;
    while (t1_irq_rx_cnt < T1_COUNT && wait_count < 500000) begin
        repeat(100) @(posedge clk);
        wait_count = wait_count + 100;
    end

    if (t1_irq_rx_cnt >= T1_COUNT)
        $display("[%0t] T1: all %0d frames received", $time, T1_COUNT);
    else
        $display("[%0t] T1: TIMEOUT, received %0d/%0d", $time, t1_irq_rx_cnt, T1_COUNT);

    $display("\n============ TEST 1 Results ============");
    $display(" No. | TX Sent | RX Got | Retries | Result");
    $display("-----------------------------------------");
    t1_err_cnt = 0;
    for (i=0; i<T1_COUNT; i=i+1) begin
        if (t1_rx_expect[i] === t1_rx_got[i])
            $display(" %3d |  0x%02X  |  0x%02X  | %7d | PASS",
                     i, t1_rx_expect[i], t1_rx_got[i], t1_tx_retries[i]);
        else begin
            $display(" %3d |  0x%02X  |  0x%02X  | %7d | FAIL <<<",
                     i, t1_rx_expect[i], t1_rx_got[i], t1_tx_retries[i]);
            t1_err_cnt = t1_err_cnt + 1;
        end
    end
    $display("T1 Overall: %s (errors=%0d)\n",
             (t1_err_cnt==0) ? "PASS" : "FAIL", t1_err_cnt);

    repeat(2000) @(posedge clk);

    // =====================================================================
    // TEST 2: B2B read/write
    // =====================================================================
    $display("\n[%0t] ===== TEST 2: APB Back-to-back Read/Write =====", $time);
    test_phase    = 2;
    t2_irq_rx_cnt = 0;
    t2_err_cnt    = 0;

    for (i=0; i<3; i=i+1) begin
        t2_expect[i]   = i + 8'hD0;
        t2_expect[i+3] = i + 8'hE0;
    end

    for (i=0; i<3; i=i+1) begin
        $display("[%0t] T2-Main: TX Round %0d, data=0x%02X", $time, i, t2_expect[i]);
        t2_isr_do_write   = 1;
        t2_isr_write_data = t2_expect[i+3];
        t2_isr_write_done = 0;
        apb_write_safe(ADDR_TX, {24'd0, t2_expect[i]});

        wait_count = 0;
        while (!t2_isr_write_done && wait_count < 200000) begin
            @(posedge clk);
            wait_count = wait_count + 1;
        end
        if (t2_isr_write_done)
            $display("[%0t] T2-Main: ISR read+write done round %0d", $time, i);
        else
            $display("[%0t] T2-Main: TIMEOUT ISR round %0d", $time, i);

        wait_count = 0;
        while (t2_irq_rx_cnt < (i+1)*2 && wait_count < 200000) begin
            @(posedge clk);
            wait_count = wait_count + 1;
        end
        repeat(100) @(posedge clk);
    end

    $display("[%0t] T2: waiting all frames...", $time);
    wait_count = 0;
    while (t2_irq_rx_cnt < T2_TOTAL && wait_count < 500000) begin
        repeat(100) @(posedge clk);
        wait_count = wait_count + 100;
    end

    $display("\n============ TEST 2 Results ============");
    $display("Phase A (Main TX -> ISR RX):");
    $display(" No. | TX Sent | RX Got | Result");
    $display("----------------------------------");
    for (i=0; i<3; i=i+1) begin
        if (t2_expect[i] === t2_got[i])
            $display(" %3d |  0x%02X  |  0x%02X  | PASS", i, t2_expect[i], t2_got[i]);
        else begin
            $display(" %3d |  0x%02X  |  0x%02X  | FAIL <<<", i, t2_expect[i], t2_got[i]);
            t2_err_cnt = t2_err_cnt + 1;
        end
    end
    $display("\nPhase B (ISR TX B2B -> ISR RX loopback):");
    $display(" No. | TX Sent | RX Got | Result");
    $display("----------------------------------");
    for (i=3; i<6; i=i+1) begin
        if (t2_expect[i] === t2_got[i])
            $display(" %3d |  0x%02X  |  0x%02X  | PASS", i-3, t2_expect[i], t2_got[i]);
        else begin
            $display(" %3d |  0x%02X  |  0x%02X  | FAIL <<<", i-3, t2_expect[i], t2_got[i]);
            t2_err_cnt = t2_err_cnt + 1;
        end
    end
    $display("\nT2 IRQ RX count: %0d (expected %0d)", t2_irq_rx_cnt, T2_TOTAL);
    $display("T2 Overall: %s (errors=%0d)\n",
             (t2_err_cnt==0 && t2_irq_rx_cnt>=T2_TOTAL) ? "PASS" : "FAIL", t2_err_cnt);

    repeat(1000) @(posedge clk);
    apb_read(ADDR_STA, sta_rd);
    $display("[%0t] Final UART Status: 0x%08X", $time, sta_rd);

    $display("\n================ Final Report ==================");
    $display("TEST 1 (32 frames safe-poll): %s", (t1_err_cnt==0) ? "PASS" : "FAIL");
    $display("TEST 2 (B2B R/W 6 transfers): %s", (t2_err_cnt==0) ? "PASS" : "FAIL");
    $display("================================================\n");

    repeat(20) @(posedge clk);
    $finish;
end

// =========================================================================
// Timeout
// =========================================================================
initial begin
    #(CLK_PERIOD * 2000000);
    $display("\n[ERROR] Simulation timeout!");
    $finish;
end

// =========================================================================
// Waveform dump
// =========================================================================
initial begin
    $dumpfile("uart_tb.vcd");
    $dumpvars(0, uart_tb);
end

endmodule