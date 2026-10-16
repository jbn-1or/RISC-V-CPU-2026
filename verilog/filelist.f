# RTL paths are relative to this file in verilog/.
# The top-level module must be named student_top.

# shared
cpu_pkg.sv

# frontend
frontend/decode.sv
frontend/bp.sv
frontend/icache.sv
frontend/fetch_unit.sv

# backend units
backend/alu.sv
backend/bru.sv
backend/mul.sv
backend/div.sv
backend/prf.sv
backend/rob.sv
backend/rename.sv
backend/iq.sv
backend/wb_skid.sv
backend/core_ooo.sv

# memory
memory/lsu_b.sv
memory/lsu_a.sv
memory/dcache.sv
memory/axi_master.sv

# top
student_top.sv
