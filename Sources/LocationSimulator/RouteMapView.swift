import AppKit
import MapKit
import SwiftUI

final class RoutePointAnnotation: MKPointAnnotation {}
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
            coordinator.renderedPoints = points
            map.removeAnnotations(map.annotations.filter { $0 is RoutePointAnnotation })
            for (index, point) in points.enumerated() {
                let annotation = RoutePointAnnotation()
                annotation.coordinate = CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
                annotation.title = "\(index + 1)"
                map.addAnnotation(annotation)
            }
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
        let routeToPreview = previewRoute.isEmpty ? points : previewRoute
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

        init(_ parent: RouteMapView) { self.parent = parent }

        func startTrackingClicks() {
            guard clickMonitor == nil else { return }
            // Observe the complete mouse sequence without competing with MapKit's pan gesture.
            clickMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
            ) { [weak self] event in
                self?.handleMouseEvent(event)
                return event
            }
        }

        func stopTrackingClicks() {
            if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
            clickMonitor = nil
            mouseDownLocation = nil
        }

        private func handleMouseEvent(_ event: NSEvent) {
            guard let map = mapView, event.window === map.window else {
                mouseDownLocation = nil
                return
            }
            let location = map.convert(event.locationInWindow, from: nil)
            switch event.type {
            case .leftMouseDown:
                mouseDownLocation = map.bounds.contains(location) && event.clickCount == 1
                    ? location : nil
            case .leftMouseDragged:
                if let down = mouseDownLocation,
                   hypot(location.x - down.x, location.y - down.y) > 5 {
                    mouseDownLocation = nil
                }
            case .leftMouseUp:
                guard let down = mouseDownLocation else { return }
                mouseDownLocation = nil
                guard map.bounds.contains(location),
                      hypot(location.x - down.x, location.y - down.y) <= 5 else { return }
                addPoint(at: location, on: map)
            default:
                break
            }
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
            return view
        }
    }
}
