import QEQAppSupport
import SwiftUI

struct HardwareAssignmentTarget: Equatable, Identifiable {
    let id: String
    let name: String
}

struct HardwareSlotButton: View {
    @ObservedObject var model: MixerModel
    let appID: String
    let appName: String
    private var assigned: [HardwareSlotBinding] { model.hardwareBindings.filter { $0.appID == appID } }
    var body: some View {
        Button {
            model.hardwareAssignment = HardwareAssignmentTarget(id: appID, name: appName)
        } label: {
            Group {
                if let slot = assigned.first {
                    Text("\(slot.number)").font(.system(size: 11, weight: .semibold, design: .rounded))
                } else {
                    Image(systemName: "slider.vertical.3").font(.system(size: 12))
                }
            }
            .foregroundStyle(assigned.isEmpty ? Color.secondary : Color.accentColor)
            .frame(width: 28, height: 26)
            .background(
                assigned.isEmpty ? Color.secondary.opacity(0.08) : Color.accentColor.opacity(0.16),
                in: RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(.plain)
            .help(
                assigned.isEmpty
                    ? "Assign a hardware slot to \(appName)"
                    : "\(appName) · Slot \(assigned.map { String($0.number) }.joined(separator: ", "))"
            )
            .accessibilityLabel("Hardware slot for \(appName)")
            .accessibilityValue(
                assigned.isEmpty ? "Unassigned" : assigned.map { "Slot \($0.number)" }.joined(separator: ", "))
    }
}

struct HardwareSlotPicker: View {
    @ObservedObject var model: MixerModel
    let target: HardwareAssignmentTarget
    private var multipleDevices: Bool { Set(model.hardwareSlots.map(\.serial)).count > 1 }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Assign hardware slot").font(.headline)
                    Text(target.name).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button {
                    model.hardwareAssignment = nil
                } label: {
                    Image(systemName: "xmark").frame(width: 24, height: 24)
                }.buttonStyle(.plain).accessibilityLabel("Close slot assignment")
            }
            if model.hardwareSlots.isEmpty {
                Text("Reconnect your controller to assign a slot.").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(model.hardwareSlots) { slot in
                            HStack(spacing: 6) {
                                Button {
                                    model.selectHardwareApp(target, slot: slot)
                                } label: {
                                    HStack(spacing: 12) {
                                        Text("\(slot.number)").font(
                                            .system(size: 17, weight: .semibold, design: .rounded)
                                        )
                                        .frame(width: 32, height: 32)
                                        .background(
                                            Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(slot.appName ?? slot.appID ?? "Unassigned").font(
                                                .system(size: 12, weight: .medium)
                                            ).lineLimit(1)
                                            Text(detail(slot)).font(.system(size: 10)).foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                        if slot.appID == target.id {
                                            Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                        }
                                    }.padding(8).contentShape(Rectangle())
                                }.buttonStyle(.plain).accessibilityLabel("Assign \(target.name) to slot \(slot.number)")
                                Button {
                                    model.calibrateHardware(slot)
                                } label: {
                                    Image(systemName: "gearshape").frame(width: 28, height: 32)
                                }.buttonStyle(.plain).foregroundStyle(.secondary)
                                    .help("Calibrate slider \(slot.number)").accessibilityLabel(
                                        "Calibrate slider \(slot.number)")
                            }.background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }.frame(height: min(232, CGFloat(model.hardwareSlots.count) * 58 - 6))
            }
            HStack {
                Text("Slots stay assigned when apps close.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.hardwareBindings.contains(where: { $0.appID == target.id }) {
                    Button("Unassign") { model.unassignHardwareApp(target.id) }
                        .accessibilityLabel("Unassign hardware slots for \(target.name)")
                }
            }
        }.padding(18).frame(maxWidth: 350)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.12)))
            .shadow(color: .black.opacity(0.2), radius: 16, y: 5)
            .accessibilityIdentifier("hardware-slot-picker")
    }
    private func detail(_ slot: HardwareSlotBinding) -> String {
        let device = multipleDevices ? " · \(slot.serial)" : ""
        if slot.appID == target.id {
            let running = model.snapshot.apps.contains { $0.id == target.id && $0.playing }
            return (running ? "Assigned to this app" : "Assigned · not playing") + device
        }
        if let id = slot.appID {
            let offline = !model.snapshot.apps.contains { $0.id == id && $0.playing }
            return (offline ? "Not playing · replace assignment" : "Replace assignment") + device
        }
        return "Available\(device)"
    }
}
