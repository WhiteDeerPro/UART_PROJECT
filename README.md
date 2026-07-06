# UART RTL

Verilog UART IP with an APB register interface, TX/RX FIFOs, baud-rate
generation, parity support, stop-bit configuration, and IRQ-driven RX reads.

## Directory Layout

- `rtls/`: UART RTL modules.
- `tbs/`: module and top-level simulation testbenches.
- `vcds/`: generated waveform dumps, ignored by Git.
- `vvps/`: generated Icarus Verilog simulation outputs, ignored by Git.

## Main RTL

- `uart.v`: top-level UART with APB, FIFOs, BRG, TX, RX, and IRQ.
- `uart_regs.v`: APB register block, configuration shadowing, TX/RX packing,
  status, error response, and IRQ generation.
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
