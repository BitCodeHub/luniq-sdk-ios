//
//  LuniqSwiftUI.swift
//  GIA — Luniq SDK SwiftUI integration
//
//  Tiny wrappers so every SwiftUI screen in the app gets one-line screen
//  tracking and action tracking without peppering `Luniq.shared.*` calls
//  through view bodies.
//
//  Usage:
//    MyView()
//      .trackScreen("vehicle_selection")
//      .trackScreen("pdf_viewer", properties: ["manual": vehicle.model])
//
//    Button("Send") { send() }
//      .trackedAs("ask_send", properties: ["turn": turnCount])
//

import SwiftUI

public extension View {
    /// Fires `Luniq.shared.screen(name, properties:)` on each `onAppear`.
    /// Safe even if Luniq hasn't been started — the SDK bails early in
    /// that case, so this is essentially a no-op for unconfigured builds.
    func trackScreen(_ name: String,
                     properties: [String: Any] = [:]) -> some View {
        self.onAppear {
            Luniq.shared.screen(name, properties: properties.isEmpty ? nil : properties)
        }
    }

    /// Fires a named event when the view appears. Use for one-shot entry
    /// events ("flow_started") that you don't want to repeat per render.
    func trackOnAppear(_ event: String,
                       properties: [String: Any] = [:]) -> some View {
        self.onAppear {
            Luniq.shared.track(event, properties: properties.isEmpty ? nil : properties)
        }
    }
}

/// Attach to any interactive element (Button, gesture) to fire an event
/// on tap without wrapping the action closure manually.
public struct TrackingModifier: ViewModifier {
    let event: String
    let properties: [String: Any]
    public func body(content: Content) -> some View {
        content.simultaneousGesture(
            TapGesture().onEnded {
                Luniq.shared.track(event,
                                     properties: properties.isEmpty ? nil : properties)
            }
        )
    }
}

public extension View {
    /// Attach a track event to any tappable view. Doesn't change the
    /// underlying action — just observes the tap.
    func trackedAs(_ event: String,
                   properties: [String: Any] = [:]) -> some View {
        modifier(TrackingModifier(event: event, properties: properties))
    }

    /// Tag a SwiftUI view as an anchor that the engage runtime can point a
    /// bubble / coachmark guide at. The view's frame is registered in
    /// global window coordinates and refreshed when layout changes, so the
    /// SDK knows exactly where to draw the spotlight + arrow.
    ///
    /// Pair with a guide whose `kind == "tooltip"` and whose first step
    /// has `anchor: "<id>"`.
    func luniqAnchor(_ id: String) -> some View {
        self.background(
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        Luniq.shared.registerAnchorFrame(id, frame: geo.frame(in: .global))
                    }
                    .onChange(of: geo.frame(in: .global)) { newFrame in
                        Luniq.shared.registerAnchorFrame(id, frame: newFrame)
                    }
            }
        )
    }
}
