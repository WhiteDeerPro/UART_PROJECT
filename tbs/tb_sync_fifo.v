`timescale 1ns/1ps

module tb_sync_fifo;

parameter DATA_WIDTH = 8;
parameter ADDR_WIDTH = 4;
parameter DEPTH      = 1 << ADDR_WIDTH;
parameter CLK_PERIOD = 10;

reg                   clk;
reg                   rst_n;
reg                   wr_en;
reg  [DATA_WIDTH-1:0] wr_data;
wire                  full;
reg                   rd_en;
wire [DATA_WIDTH-1:0] rd_data;
wire                  empty;
wire [ADDR_WIDTH:0]   data_cnt;
wire                  overflow;
wire                  underflow;

integer pass_cnt;
integer fail_cnt;

initial clk = 0;
always #(CLK_PERIOD/2) clk = ~clk;

sync_fifo #(
    .DATA_WIDTH (DATA_WIDTH),
    .ADDR_WIDTH (ADDR_WIDTH),
    .FWFT_EN    (1)
) u_fifo (
    .clk       (clk),
    .rst_n     (rst_n),
    .wr_en     (wr_en),
    .wr_data   (wr_data),
    .full      (full),
    .rd_en     (rd_en),
    .rd_data   (rd_data),
    .empty     (empty),
    .data_cnt  (data_cnt),
    .overflow  (overflow),
    .underflow (underflow)
);

// ----------------------------------------------------------------
// 参考模型
// ----------------------------------------------------------------
reg [DATA_WIDTH-1:0] ref_queue [0:DEPTH];
integer ref_head, ref_tail, ref_cnt;

task ref_reset;
    begin
        ref_head = 0; ref_tail = 0; ref_cnt = 0;
    end
endtask

task ref_push;
    input [DATA_WIDTH-1:0] d;
    begin
        if (ref_cnt < DEPTH) begin
            ref_queue[ref_tail] = d;
            ref_tail = (ref_tail + 1) % (DEPTH + 1);
            ref_cnt  = ref_cnt + 1;
        end
    end
endtask

task ref_pop;
    output [DATA_WIDTH-1:0] d;
    begin
        if (ref_cnt > 0) begin
            d        = ref_queue[ref_head];
            ref_head = (ref_head + 1) % (DEPTH + 1);
            ref_cnt  = ref_cnt - 1;
        end else
            d = {DATA_WIDTH{1'bx}};
    end
endtask

// ----------------------------------------------------------------
// 检查任务
// ----------------------------------------------------------------
task check;
    input [63:0]  line;
    input [127:0] name;
    input         got;
    input         exp;
    begin
        if (got === exp) begin
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("[FAIL] line=%0d  %s : got=%0b  exp=%0b", line, name, got, exp);
            fail_cnt = fail_cnt + 1;
        end
    end
endtask

task check_data;
    input [63:0]           line;
    input [DATA_WIDTH-1:0] got;
    input [DATA_WIDTH-1:0] exp;
    begin
        if (got === exp) begin
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("[FAIL] line=%0d  rd_data : got=0x%02X  exp=0x%02X", line, got, exp);
            fail_cnt = fail_cnt + 1;
        end
    end
endtask

// ----------------------------------------------------------------
// 操作任务
// ----------------------------------------------------------------

// 写入一个数据
task do_write;
    input [DATA_WIDTH-1:0] d;
    begin
        @(posedge clk); #1;
        wr_en   = 1'b1;
        wr_data = d;
        if (!full) ref_push(d);
        @(posedge clk); #1;
        wr_en = 1'b0;
    end
endtask

// FWFT 读：先采样头数据，再给使能让指针移动
task do_read;
    output [DATA_WIDTH-1:0] d;
    begin
        @(posedge clk); #1;
        d     = rd_data;   // 此时指针未变，采样当前头
        rd_en = 1'b1;
        @(posedge clk); #1;
        rd_en = 1'b0;
    end
endtask

task idle;
    input integer n;
    begin
        wr_en = 0;
        rd_en = 0;
        repeat (n) @(posedge clk);
    end
endtask

// ----------------------------------------------------------------
// 主激励
// ----------------------------------------------------------------
integer i;
reg [DATA_WIDTH-1:0] rdata;
reg [DATA_WIDTH-1:0] exp_data;
reg [DATA_WIDTH-1:0] snapshot;

initial begin
    pass_cnt = 0; fail_cnt = 0;
    wr_en = 0; rd_en = 0; wr_data = 0;
    rst_n = 0;
    ref_reset;

    $display("========================================");
    $display("  sync_fifo Testbench  DEPTH=%0d  FWFT=1", DEPTH);
    $display("========================================");

    repeat (5) @(posedge clk);
    rst_n = 1;
    @(posedge clk); #1;

    // --------------------------------------------------------
    // TEST 1：复位后状态
    // --------------------------------------------------------
    $display("\n[TEST 1] Reset state");
    check(`__LINE__, "empty", empty, 1'b1);
    check(`__LINE__, "full",  full,  1'b0);
    check(`__LINE__, "cnt=0", (data_cnt == 0), 1'b1);

    // --------------------------------------------------------
    // TEST 2：单次写读
    // --------------------------------------------------------
    $display("\n[TEST 2] Single write then read");
    do_write(8'hA5);
    idle(1);
    // FWFT：写入后 rd_data 立即反映头数据
    @(posedge clk); #1;
    check_data(`__LINE__, rd_data, 8'hA5);
    check(`__LINE__, "empty=0", empty, 1'b0);
    check(`__LINE__, "cnt=1",   (data_cnt == 1), 1'b1);

    do_read(rdata);
    check_data(`__LINE__, rdata, 8'hA5);
    idle(1);
    check(`__LINE__, "empty after read", empty, 1'b1);
    check(`__LINE__, "cnt=0  after read",(data_cnt == 0), 1'b1);

    // --------------------------------------------------------
    // TEST 3：写满
    // --------------------------------------------------------
    $display("\n[TEST 3] Fill to full");
    ref_reset;
    for (i = 0; i < DEPTH; i = i + 1)
        do_write(i[DATA_WIDTH-1:0]);
    idle(1);
    check(`__LINE__, "full  after fill", full,  1'b1);
    check(`__LINE__, "empty after fill", empty, 1'b0);
    check(`__LINE__, "cnt==DEPTH",       (data_cnt == DEPTH), 1'b1);

    // --------------------------------------------------------
    // TEST 4：满时写 overflow
    // --------------------------------------------------------
    $display("\n[TEST 4] Write when full -> overflow");
    @(posedge clk); #1;
    wr_en   = 1'b1;
    wr_data = 8'hFF;
    @(posedge clk); #1;
    check(`__LINE__, "overflow", overflow, 1'b1);
    check(`__LINE__, "full",     full,     1'b1);
    wr_en = 1'b0;
    idle(1);

    // --------------------------------------------------------
    // TEST 5：顺序读出验证
    // --------------------------------------------------------
    $display("\n[TEST 5] Sequential read & verify");
    for (i = 0; i < DEPTH; i = i + 1) begin
        ref_pop(exp_data);
        do_read(rdata);
        check_data(`__LINE__, rdata, exp_data);
    end
    idle(1);
    check(`__LINE__, "empty after drain", empty, 1'b1);

    // --------------------------------------------------------
    // TEST 6：空时读 underflow
    // --------------------------------------------------------
    $display("\n[TEST 6] Read when empty -> underflow");
    @(posedge clk); #1;
    rd_en = 1'b1;
    @(posedge clk); #1;
    check(`__LINE__, "underflow", underflow, 1'b1);
    check(`__LINE__, "empty",     empty,     1'b1);
    rd_en = 1'b0;
    idle(1);

    // --------------------------------------------------------
    // TEST 7：同时读写
    // --------------------------------------------------------
    $display("\n[TEST 7] Simultaneous read & write");
    do_write(8'h11);
    idle(1);
    check(`__LINE__, "cnt=1 before", (data_cnt == 1), 1'b1);

    @(posedge clk); #1;
    snapshot = rd_data;        // 采样当前头（0x11），指针未动
    wr_en    = 1'b1;
    wr_data  = 8'h22;
    rd_en    = 1'b1;
    @(posedge clk); #1;
    wr_en = 1'b0;
    rd_en = 1'b0;
    check_data(`__LINE__, snapshot, 8'h11);
    idle(1);
    check(`__LINE__, "cnt=1 after sim-rw", (data_cnt == 1), 1'b1);

    // 再读出 0x22
    do_read(rdata);
    check_data(`__LINE__, rdata, 8'h22);
    idle(1);
    check(`__LINE__, "empty after sim-rw", empty, 1'b1);

    // --------------------------------------------------------
    // TEST 8：随机交替读写（数据完整性）
    // --------------------------------------------------------
    $display("\n[TEST 8] Random interleaved write/read");
    ref_reset;
    begin : rand_test
        integer j;
        reg [DATA_WIDTH-1:0] wval;
        for (j = 0; j < 64; j = j + 1) begin
            wval = $random & 8'hFF;
            if (!full) begin
                do_write(wval);
            end
            if (!empty && (j % 3 == 0)) begin
                ref_pop(exp_data);
                do_read(rdata);
                check_data(`__LINE__, rdata, exp_data);
            end
        end
        while (!empty) begin
            ref_pop(exp_data);
            do_read(rdata);
            check_data(`__LINE__, rdata, exp_data);
        end
    end
    check(`__LINE__, "empty after random", empty, 1'b1);

    // --------------------------------------------------------
    // TEST 9：中途复位
    // --------------------------------------------------------
    $display("\n[TEST 9] Mid-operation reset");
    do_write(8'hBB);
    do_write(8'hCC);
    idle(1);
    check(`__LINE__, "cnt=2 before rst", (data_cnt == 2), 1'b1);
    rst_n = 0;
    repeat (3) @(posedge clk);
    rst_n = 1;
    @(posedge clk); #1;
    check(`__LINE__, "empty after rst", empty, 1'b1);
    check(`__LINE__, "full  after rst", full,  1'b0);
    check(`__LINE__, "cnt=0 after rst", (data_cnt == 0), 1'b1);

    // --------------------------------------------------------
    // 汇总
    // --------------------------------------------------------
    idle(5);
    $display("\n========================================");
    $display("  PASS : %0d", pass_cnt);
    $display("  FAIL : %0d", fail_cnt);
    if (fail_cnt == 0)
        $display("  ALL TESTS PASSED");
    else
        $display("  *** SOME TESTS FAILED ***");
    $display("========================================");
    $finish;
end

initial begin
    #1_000_000;
    $display("[TIMEOUT]");
    $finish;
end

initial begin
    $dumpfile("tb_sync_fifo.vcd");
    $dumpvars(0, tb_sync_fifo);
end

endmodule