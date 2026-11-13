import AppKit
import MapKit
import SwiftUI

final class RoutePointAnnotation: MKPointAnnotation { var index = 0 }
final class SearchPointAnnotation: MKPointAnnotation {}
final class SinglePointAnnotation: MKPointAnnotation {}

struct RouteMapView: NSViewRepresentable {
    let points: [Coordinate]
    let previewRoute: [Coordinate]
    let variationMeters: Double
    let previewSeed: UInt64
    let fitRevision: Int
    let searchCoordinate: Coordinate?
    let searchTitle: String
    let focusRevision: Int
    let singlePoint: Coordinate?
    let editable: Bool
    let onPointMoved: (Int, Coordinate) -> Void
    let onMapClick: (Coordinate) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsCompass = true
        map.showsZoomControls = true
        map.pointOfInterestFilter = .excludingAll
        map.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 39.9042, longitude: 116.4074),
                                         span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)),
                      animated: false)
        context.coordinator.mapView = map
        context.coordinator.startTrackingClicks()
        return map
    }

    static func dismantleNSView(_ map: MKMapView, coordinator: Coordinator) {
        coordinator.stopTrackingClicks()
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if coordinator.renderedPoints != points {
            coordinator.cancelDrag()
            coordinator.renderedPoints = points
            map.removeAnnotations(map.annotations.filter { $0 is RoutePointAnnotation })
            for (index, point) in points.enumerated() {
                if points.count > 1 && index == points.count - 1 && point == points.first { continue }
                let annotation = RoutePointAnnotation()
                annotation.index = index
                annotation.coordinate = CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
                annotation.title = "\(index + 1)"
                map.addAnnotation(annotation)
            }
        }
        if coordinator.renderedEditable != editable {
            coordinator.renderedEditable = editable
            if !editable { coordinator.cancelDrag() }
        }
        if coordinator.renderedSearchCoordinate != searchCoordinate
            || coordinator.renderedSearchTitle != searchTitle {
            coordinator.renderedSearchCoordinate = searchCoordinate
            coordinator.renderedSearchTitle = searchTitle
            if let old = coordinator.searchAnnotation { map.removeAnnotation(old) }
            coordinator.searchAnnotation = nil
            if let searchCoordinate {
                let annotation = SearchPointAnnotation()
                annotation.coordinate = CLLocationCoordinate2D(latitude: searchCoordinate.latitude,
                                                               longitude: searchCoordinate.longitude)
                annotation.title = searchTitle
                map.addAnnotation(annotation)
                coordinator.searchAnnotation = annotation
            }
        }
        if coordinator.renderedSinglePoint != singlePoint {
            coordinator.renderedSinglePoint = singlePoint
            map.removeAnnotations(map.annotations.filter { $0 is SinglePointAnnotation })
            if let singlePoint {
                let annotation = SinglePointAnnotation()
                annotation.coordinate = CLLocationCoordinate2D(latitude: singlePoint.latitude,
                                                               longitude: singlePoint.longitude)
                annotation.title = "单点定位"
                map.addAnnotation(annotation)
            }
        }
        let routeToPreview = previewRoute.isEmpty ? RouteLoop.closed(points) : previewRoute
        if coordinator.renderedPreviewRoute != routeToPreview
            || coordinator.renderedVariation != variationMeters
            || coordinator.renderedSeed != previewSeed {
            coordinator.renderedPreviewRoute = routeToPreview
            coordinator.renderedVariation = variationMeters
            coordinator.renderedSeed = previewSeed
            map.removeOverlays(map.overlays)
            let samples = RoutePreview.sample(points: routeToPreview,
                                              variationMeters: variationMeters,
                                              seed: previewSeed)
            if samples.count >= 2 {
                let coordinates = samples.map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                }
                map.addOverlay(MKPolyline(coordinates: coordinates, count: coordinates.count))
            }
        }
        if coordinator.lastFitRevision != fitRevision {
            coordinator.lastFitRevision = fitRevision
            guard !points.isEmpty else { return }
            if points.count == 1 {
                map.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: points[0].latitude,
                                                                               longitude: points[0].longitude),
                                                 span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)),
                              animated: true)
            } else {
                let coordinates = points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                let line = MKPolyline(coordinates: coordinates, count: coordinates.count)
                map.setVisibleMapRect(line.boundingMapRect,
                                      edgePadding: NSEdgeInsets(top: 70, left: 70, bottom: 70, right: 70),
                                      animated: true)
            }
        }
        if coordinator.lastFocusRevision != focusRevision {
            coordinator.lastFocusRevision = focusRevision
            if let searchCoordinate {
                map.setRegion(MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: searchCoordinate.latitude,
                                                   longitude: searchCoordinate.longitude),
                    span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012)
                ), animated: true)
            }
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: RouteMapView
        weak var mapView: MKMapView?
        var renderedPoints: [Coordinate] = []
        var renderedEditable: Bool?
        var renderedPreviewRoute: [Coordinate] = []
        var renderedVariation = -1.0
        var renderedSeed: UInt64 = 0
        var lastFitRevision = -1
        var renderedSearchCoordinate: Coordinate?
        var renderedSearchTitle = ""
        var searchAnnotation: SearchPointAnnotation?
        var renderedSinglePoint: Coordinate?
        var lastFocusRevision = -1
        private var clickMonitor: Any?
        private var mouseDownLocation: NSPoint?
        private var draggedAnnotation: RoutePointAnnotation?
        private var dragStartLocation: NSPoint?
        private var dragStartCoordinate: CLLocationCoordinate2D?
        private var didMoveDraggedAnnotation = false

        init(_ parent: RouteMapView) { self.parent = parent }

        func startTrackingClicks() {
            guard clickMonitor == nil else { return }
            // Observe the complete mouse sequence without competing with MapKit's pan gesture.
            clickMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
            ) { [weak self] event in
                self?.handleMouseEvent(event) == true ? nil : event
            }
        }

        func stopTrackingClicks() {
            if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
            clickMonitor = nil
            mouseDownLocation = nil
            cancelDrag()
        }

        private func handleMouseEvent(_ event: NSEvent) -> Bool {
            guard let map = mapView, event.window === map.window else {
                mouseDownLocation = nil
                cancelDrag()
                return false
            }
            let location = map.convert(event.locationInWindow, from: nil)
            return handleMouseInteraction(event.type, at: location, on: map,
                                          clickCount: event.clickCount)
        }

        /// Handle route-marker dragging before MapKit can interpret the same mouse
        /// movement as a map pan. The local monitor also works when a SwiftUI view
        /// above the map receives the original mouse event.
        @discardableResult
        func handleMouseInteraction(_ type: NSEvent.EventType, at location: NSPoint,
                                    on map: MKMapView, clickCount: Int = 1) -> Bool {
            switch type {
            case .leftMouseDown:
                if parent.editable, map.bounds.contains(location), clickCount == 1,
                   let annotation = routeAnnotation(at: location, on: map) {
                    draggedAnnotation = annotation
                    dragStartCoordinate = annotation.coordinate
                    dragStartLocation = location
                    didMoveDraggedAnnotation = false
                    mouseDownLocation = nil
                    return true
                }
                mouseDownLocation = map.bounds.contains(location) && clickCount == 1 ? location : nil
            case .leftMouseDragged:
                if let annotation = draggedAnnotation {
                    if let start = dragStartLocation,
                       hypot(location.x - start.x, location.y - start.y) > 4 {
                        didMoveDraggedAnnotation = true
                    }
                    if didMoveDraggedAnnotation,
                       let point = coordinate(at: location, on: map) {
                        annotation.coordinate = point
                        showDraggingRoute(on: map, moving: annotation)
                    }
                    return true
                }
                if let down = mouseDownLocation,
                   hypot(location.x - down.x, location.y - down.y) > 5 {
                    mouseDownLocation = nil
                }
            case .leftMouseUp:
                if let annotation = draggedAnnotation {
                    if didMoveDraggedAnnotation, map.bounds.contains(location),
                       let point = coordinate(at: location, on: map) {
                        annotation.coordinate = point
                        finishDrag(annotation)
                    } else {
                        annotation.coordinate = dragStartCoordinate ?? annotation.coordinate
                        restoreRoutePreview(on: map)
                    }
                    clearDrag()
                    return true
                }
                guard let down = mouseDownLocation else { return false }
                mouseDownLocation = nil
                guard map.bounds.contains(location),
                      hypot(location.x - down.x, location.y - down.y) <= 5 else { return false }
                addPoint(at: location, on: map)
            default:
                break
            }
            return false
        }

        private func routeAnnotation(at location: NSPoint, on map: MKMapView) -> RoutePointAnnotation? {
            let candidates = map.annotations.compactMap { $0 as? RoutePointAnnotation }
            return candidates.filter { annotation in
                let anchor = map.convert(annotation.coordinate, toPointTo: map)
                let distance = hypot(location.x - anchor.x, location.y - anchor.y)
                if let view = map.view(for: annotation) {
                    let frame = view.convert(view.bounds, to: map).insetBy(dx: -6, dy: -6)
                    return frame.contains(location) || distance <= 18
                }
                return distance <= 26
            }.min { a, b in
                let first = map.convert(a.coordinate, toPointTo: map)
                let second = map.convert(b.coordinate, toPointTo: map)
                return hypot(location.x - first.x, location.y - first.y)
                    < hypot(location.x - second.x, location.y - second.y)
            }
        }

        private func coordinate(at location: NSPoint, on map: MKMapView) -> CLLocationCoordinate2D? {
            let coordinate = map.convert(location, toCoordinateFrom: map)
            guard (try? Coordinate(latitude: coordinate.latitude,
                                   longitude: coordinate.longitude)) != nil else { return nil }
            return coordinate
        }

        private func showDraggingRoute(on map: MKMapView, moving annotation: RoutePointAnnotation) {
            guard parent.points.count > 1, parent.points.indices.contains(annotation.index) else { return }
            var coordinates = parent.points.map {
                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
            }
            coordinates[annotation.index] = annotation.coordinate
            if coordinates.last?.latitude != coordinates.first?.latitude
                || coordinates.last?.longitude != coordinates.first?.longitude {
                coordinates.append(coordinates[0])
            }
            map.removeOverlays(map.overlays)
            map.addOverlay(MKPolyline(coordinates: coordinates, count: coordinates.count))
        }

        private func restoreRoutePreview(on map: MKMapView) {
            let route = parent.previewRoute.isEmpty ? RouteLoop.closed(parent.points) : parent.previewRoute
            let samples = RoutePreview.sample(points: route, variationMeters: parent.variationMeters,
                                              seed: parent.previewSeed)
            map.removeOverlays(map.overlays)
            if samples.count >= 2 {
                let coordinates = samples.map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                }
                map.addOverlay(MKPolyline(coordinates: coordinates, count: coordinates.count))
            }
        }

        private func clearDrag() {
            draggedAnnotation = nil
            dragStartCoordinate = nil
            dragStartLocation = nil
            didMoveDraggedAnnotation = false
        }

        func cancelDrag() {
            if let annotation = draggedAnnotation, let original = dragStartCoordinate {
                annotation.coordinate = original
                if let map = mapView { restoreRoutePreview(on: map) }
            }
            clearDrag()
        }

        private func addPoint(at location: NSPoint, on map: MKMapView) {
            var hitView = map.hitTest(location)
            while let view = hitView {
                if view is MKAnnotationView || view is NSControl { return }
                hitView = view.superview
            }
            let coordinate = map.convert(location, toCoordinateFrom: map)
            guard let point = try? Coordinate(latitude: coordinate.latitude, longitude: coordinate.longitude) else { return }
            parent.onMapClick(point)
        }

        deinit { stopTrackingClicks() }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKPolylineRenderer(polyline: line)
            renderer.strokeColor = .systemTeal
            renderer.lineWidth = 4
            renderer.lineJoin = .round
            renderer.lineCap = .round
            return renderer
        }

        private func finishDrag(_ annotation: RoutePointAnnotation) {
            guard parent.editable, annotation.index < parent.points.count,
                  let point = try? Coordinate(latitude: annotation.coordinate.latitude,
                                              longitude: annotation.coordinate.longitude),
                  parent.points[annotation.index] != point else { return }
            parent.onPointMoved(annotation.index, point)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard annotation is RoutePointAnnotation || annotation is SearchPointAnnotation
                    || annotation is SinglePointAnnotation else { return nil }
            let isSearch = annotation is SearchPointAnnotation
            let isSinglePoint = annotation is SinglePointAnnotation
            let identifier = isSearch ? "SearchPoint" : (isSinglePoint ? "SinglePoint" : "RoutePoint")
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            view.annotation = annotation
            view.markerTintColor = isSearch ? .systemOrange : (isSinglePoint ? .systemPurple : .systemTeal)
            view.glyphText = isSearch ? "⌕" : (isSinglePoint ? "◎" : (annotation.title ?? "•"))
            view.canShowCallout = isSearch || isSinglePoint
            // The coordinator handles mouse dragging so MapKit cannot pan the map
            // instead of moving a marker.
            view.isDraggable = false
            return view
        }
    }
}
