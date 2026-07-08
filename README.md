# UART RTL

Verilog UART IP with an APB register interface, TX/RX FIFOs, baud-rate
generation, parity support, stop-bit configuration, TX burst writes, and
single-byte IRQ-driven RX reads.

## Directory Layout

- `rtls/`: UART RTL modules.
- `tbs/`: module and top-level simulation testbenches.
- `vcds/`: generated waveform dumps, ignored by Git.
- `vvps/`: generated Icarus Verilog simulation outputs, ignored by Git.

## Authors

- WhiteDeerPro <1207707136@qq.com>
- 10kyfu <2194438514@qq.com>
- strive2021 <xiligongda@outlook.com>

## Main RTL

- `uart.v`: top-level UART with APB, FIFOs, BRG, TX, RX, and IRQ.
- `uart_regs.v`: APB register block, configuration shadowing, TX burst packing,
  single-byte RX latch, status, error response, and IRQ generation.
- `uart_tx.v`: single-byte UART transmitter.
- `uart_rx.v`: 16x oversampling UART receiver.
- `uart_fifo.v`: synchronous FWFT FIFO.
- `uart_brg.v`: baud-rate tick generator.
- `apb_master.v`: APB master helper used by simulations.

## APB Register Map

| Address | Register |
| --- | --- |
| `0x00` | `CFG` |
| `0x04` | `TX` |
| `0x08` | `RX` |
| `0x0C` | `STATUS` |

## Example Simulation

### VCS and Verdi

The root `Makefile` provides VCS compile/run and Verdi debug targets. The
default test is `uart_1`.

```sh
make uart_1
make uart_1_verdi
```

Other top-level loopback tests:

```sh
make uart_0
make uart_2
```

The VCS flow writes FSDB files under `build/<test>/` when compiled with
`+define+DUMP_FSDB`, which is enabled by the Makefile.

### Icarus Verilog

Install Icarus Verilog, then compile one top-level testbench with the RTL:

```sh
iverilog -o sim.vvp \
  tbs/uart_1_tb.v \
  rtls/uart.v rtls/uart_brg.v rtls/uart_fifo.v \
  rtls/uart_regs.v rtls/uart_rx.v rtls/uart_tx.v

vvp sim.vvp
```

Some older standalone testbenches may need port-name updates before they match
the current RTL.

## Configuration Notes

- `CFG[15:0]`: baud divider.
- `CFG[18:16]`: RX parity and stop-bit configuration.
- `CFG[21:19]`: TX parity and stop-bit configuration.
- `CFG[23:22]`: reserved. RX register reads are always single-byte.
- `CFG[25:24]`: TX write burst mode, mapping to 1/2/3 bytes.
