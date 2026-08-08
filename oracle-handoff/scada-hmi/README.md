# AquaPure SCADA HMI starter

This is a vendor-neutral industrial HMI/SCADA demo for a simulated water-treatment transfer skid. It includes:

- live process tags over Server-Sent Events (SSE)
- simulated PLC scan loop with tank levels, flow, pressure, pH, temperature, pump, and valve status
- operator commands for start/stop, inlet valve open/close, and AUTO/MANUAL mode
- active alarm evaluation and acknowledge-all workflow
- short-term trends and an operator audit log with JSON export
- responsive dark HMI layout that runs in a normal browser

## Run

Requires Node.js 18 or newer.

```powershell
npm start
```

Then open [http://localhost:8080](http://localhost:8080).

Use `PORT=9000 npm start` (or `$env:PORT=9000; npm start` in PowerShell) to select a different port.

## Important

This application is intentionally a simulator. It does not connect to or control physical equipment. A production deployment needs a validated PLC/RTU driver, OPC UA or Modbus gateway, authentication and authorization, network segmentation, command interlocks, historian storage, redundancy, alarm management procedures, and a formal safety review before any control output is enabled.
