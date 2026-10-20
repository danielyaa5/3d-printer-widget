import Foundation

extension PrinterKind {
    var addressLabel: String {
        switch self {
        case .bambu: return "IP address"
        case .moonraker: return "Moonraker URL"
        case .creality, .sdcp: return "WebSocket URL"
        default: return "Printer server URL"
        }
    }
    var addressExample: String {
        switch self {
        case .bambu: return "printer.local"
        case .moonraker: return "http://printer.local:7125"
        case .creality: return "ws://printer.local:9999"
        case .sdcp: return "ws://printer.local:3030/websocket"
        default: return "http://printer.local"
        }
    }
    var connectionHelp: String {
        switch self {
        case .bambu:
            return "Find the address, serial number and LAN access code in the printer’s network settings. Pair on a trusted local network. Newer firmware may require LAN Only and Developer Mode for pause, resume and stop."
        case .moonraker:
            return "Use the Moonraker, Fluidd or Mainsail address, usually ending in :7125, :4408 or :4409. Covers Klipper printers with Moonraker, including compatible Voron, Creality, Elegoo and Anycubic setups."
        case .octoPrint:
            return "Use your OctoPrint server’s address and an API key with status permission, plus Print permission for pause, resume and stop. The printer must already be connected to OctoPrint."
        case .prusaLink:
            return "Use the local PrusaLink address and its API key or local username and password, as shown in the printer’s network settings. These are separate from your Prusa Connect cloud login."
        case .duet:
            return "Use the address of Duet Web Control. Supports RepRapFirmware and Duet Software Framework. Enter the machine password if set; blank uses the factory default."
        case .creality:
            return "For K1, K1 Max and K1C firmware exposing Creality’s local status service on port 9999. No Moonraker installation is needed. Other Creality firmware may use a different interface."
        case .sdcp:
            return "For networked SDCP v3 printers, including compatible Elegoo Saturn and Mars models. Uses port 3030 and discovers the entered printer on UDP port 3000. USB-only models are not supported."
        }
    }
    var connectionSymbol: String {
        switch self {
        case .moonraker: return "network"
        case .duet: return "cpu"
        case .sdcp: return "cube.transparent"
        default: return "printer.fill"
        }
    }
}
