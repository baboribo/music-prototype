import SwiftUI
import UIKit

// Full-screen playback transition. Geometry and snapshots use only app-owned views.
@MainActor
final class InteractivePlayerContext {
    fileprivate weak var sourceView: UIView?
    fileprivate var regions: [WeakPlayerRegion] = []
    fileprivate var dismissAction: (() -> Void)?
    fileprivate var elements: [InteractivePlayerElementRole: WeakPlayerElement] = [:]

    /// Semantic Close/VoiceOver escape. The presentation binding changes only
    /// after a successful dismissal, not when this request is made.
    func dismiss() { dismissAction?() }

    fileprivate func sourceRect(in container: UIView) -> CGRect? {
        guard let sourceView, sourceView.window != nil,
              sourceView.window === container.window else { return nil }
        let rect = sourceView.convert(sourceView.bounds, to: container)
        guard rect.width > 1, rect.height > 1,
              rect.minX.isFinite, rect.minY.isFinite else { return nil }
        return rect
    }

    fileprivate func permitsPan(at point: CGPoint, in surface: UIView) -> Bool {
        regions.removeAll { $0.view == nil }
        let hits = regions.compactMap(\.view).filter { marker in
            guard marker.window != nil, marker.window === surface.window,
                  !marker.isHidden, marker.alpha > 0.01 else { return false }
            return marker.bounds.contains(marker.convert(point, from: surface))
        }
        // An exclusion wins over every allowed region. No region means no pan.
        return hits.contains { $0.kind == .allowed }
            && !hits.contains { $0.kind == .excluded }
    }

    fileprivate func register(_ view: UIView, role: InteractivePlayerElementRole, active: Bool, fullyVisible: Bool, cornerRadius: CGFloat) {
        if active {
            elements[role] = WeakPlayerElement(view, fullyVisible: fullyVisible, cornerRadius: cornerRadius)
        } else if elements[role]?.view === view {
            elements[role] = nil
        }
    }
}

enum InteractivePlayerElementRole: Hashable {
    case miniArtwork, fullArtwork
}

private struct InteractivePlayerContextKey: EnvironmentKey {
    static let defaultValue: InteractivePlayerContext? = nil
}

extension EnvironmentValues {
    var interactivePlayerTransitionContext: InteractivePlayerContext? {
        get { self[InteractivePlayerContextKey.self] }
        set { self[InteractivePlayerContextKey.self] = newValue }
    }
}

/// Own the specific artwork/backdrop subtree so snapshots and temporary alpha
/// changes never depend on finding SwiftUI's private parent/subview structure.
struct InteractivePlayerElement<Content: View>: View {
    let role: InteractivePlayerElementRole
    let context: InteractivePlayerContext?
    var isActive = true
    var isFullyVisible = true
    var cornerRadius: CGFloat = 0
    @ViewBuilder let content: () -> Content

    var body: some View {
        if let context {
            OwnedPlayerElement(role: role, owner: context, isActive: isActive,
                               isFullyVisible: isFullyVisible, cornerRadius: cornerRadius, content: content)
        } else {
            content()
        }
    }
}

private struct OwnedPlayerElement<Content: View>: UIViewControllerRepresentable {
    let role: InteractivePlayerElementRole
    let owner: InteractivePlayerContext
    let isActive: Bool
    let isFullyVisible: Bool
    let cornerRadius: CGFloat
    @ViewBuilder let content: () -> Content

    func makeUIViewController(context: Context) -> UIHostingController<Content> {
        let host = UIHostingController(rootView: content())
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        // The outer SwiftUI view already determines this element's exact rect.
        host.safeAreaRegions = []
        owner.register(host.view, role: role, active: isActive, fullyVisible: isFullyVisible, cornerRadius: cornerRadius)
        return host
    }

    func updateUIViewController(_ uiViewController: UIHostingController<Content>, context: Context) {
        withTransaction(context.transaction) { uiViewController.rootView = content() }
        owner.register(uiViewController.view, role: role, active: isActive, fullyVisible: isFullyVisible, cornerRadius: cornerRadius)
    }
}

@MainActor
fileprivate final class WeakPlayerElement {
    weak var view: UIView?
    let fullyVisible: Bool
    let cornerRadius: CGFloat
    init(_ view: UIView, fullyVisible: Bool, cornerRadius: CGFloat) {
        self.view = view
        self.fullyVisible = fullyVisible
        self.cornerRadius = cornerRadius
    }
}

/// Apply as Mini's background. It measures only this app-owned view.
struct InteractivePlayerSourceAnchor: UIViewRepresentable {
    let context: InteractivePlayerContext

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        self.context.sourceView = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        self.context.sourceView = uiView
    }
}

/// Explicit gesture geometry; does not intercept taps or inspect SwiftUI internals.
struct InteractivePlayerDismissRegion: UIViewRepresentable {
    enum Kind: Equatable { case allowed, excluded }
    let context: InteractivePlayerContext
    let kind: Kind

    func makeUIView(context: Context) -> PlayerRegionMarker {
        let view = PlayerRegionMarker()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.kind = kind
        self.context.regions.append(WeakPlayerRegion(view))
        return view
    }

    func updateUIView(_ uiView: PlayerRegionMarker, context: Context) {
        uiView.kind = kind
    }
}

@MainActor
final class PlayerRegionMarker: UIView {
    fileprivate var kind = InteractivePlayerDismissRegion.Kind.excluded
}

@MainActor
fileprivate final class WeakPlayerRegion {
    weak var view: PlayerRegionMarker?
    init(_ view: PlayerRegionMarker) { self.view = view }
}

/// Attach once to AppShell. Opening is a true binding; closing uses context.dismiss().
struct InteractivePlayerPresenter<Content: View>: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let context: InteractivePlayerContext
    let reduceMotion: Bool
    @ViewBuilder let content: () -> Content

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> PlayerPresenterAttachment {
        let controller = PlayerPresenterAttachment()
        context.coordinator.attachment = controller
        controller.onReady = { [weak coordinator = context.coordinator] in
            coordinator?.reconcile()
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: PlayerPresenterAttachment, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        // Read the Binding during SwiftUI's update so changes invalidate this
        // representable; reading it only in the deferred Task misses tracking.
        coordinator.requestedPresentation = isPresented
        coordinator.attachment = uiViewController
        self.context.dismissAction = { [weak coordinator] in coordinator?.requestDismissal() }
        if let host = coordinator.host { host.rootView = content() }
        // Presentation can update a Binding during completion; keep it out of
        // SwiftUI's synchronous representable update transaction.
        Task { @MainActor [weak coordinator] in coordinator?.reconcile() }
    }

    static func dismantleUIViewController(_ uiViewController: PlayerPresenterAttachment, coordinator: Coordinator) {
        uiViewController.onReady = nil
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, UIViewControllerTransitioningDelegate, UIGestureRecognizerDelegate {
        enum Phase: Equatable { case idle, presenting, presented, dismissing }
        var parent: InteractivePlayerPresenter
        var requestedPresentation = false
        weak var attachment: PlayerPresenterAttachment?
        var host: UIHostingController<Content>?
        private var phase = Phase.idle
        private var dismissAfterPresentation = false
        private var pan: UIPanGestureRecognizer?
        private var isDragging = false
        private var settleAnimator: UIViewPropertyAnimator?
        private var releaseVelocity: CGFloat = 0
        private weak var touchedScrollView: UIScrollView?
        private var dimmingView: UIView? {
            (host?.presentationController as? PlayerSurfacePresentationController)?.dimmingView
        }
        private var isDetached = false

        init(_ parent: InteractivePlayerPresenter) { self.parent = parent }

        func reconcile() {
            guard !isDetached else { return }
            if requestedPresentation {
                guard phase == .idle, let attachment,
                      attachment.viewIfLoaded?.window != nil,
                      attachment.presentedViewController == nil else { return }
                let host = PlayerHostingController(rootView: parent.content())
                host.overrideUserInterfaceStyle = .dark
                host.modalPresentationStyle = .custom
                host.modalPresentationCapturesStatusBarAppearance = true
                host.transitioningDelegate = self
                let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
                pan.maximumNumberOfTouches = 1
                pan.cancelsTouchesInView = true
                pan.delegate = self
                host.view.addGestureRecognizer(pan)
                self.host = host
                self.pan = pan
                phase = .presenting
                attachment.present(host, animated: true)
            } else if phase != .idle {
                requestDismissal()
            }
        }

        func requestDismissal() {
            guard !isDetached else { return }
            switch phase {
            case .presenting:
                dismissAfterPresentation = true
            case .presented:
                guard !isDragging else { return }
                releaseVelocity = 0
                phase = .dismissing
                host?.dismiss(animated: true)
            case .idle, .dismissing:
                break
            }
        }

        func detach() {
            isDetached = true
            parent.context.dismissAction = nil
            host?.dismiss(animated: false)
            host = nil
            pan = nil
            phase = .idle
        }

        private func transitionEnded(presenting: Bool, completed: Bool) {
            guard !isDetached else { return }
            releaseVelocity = 0
            if presenting, completed {
                phase = .presented
                if dismissAfterPresentation || !requestedPresentation {
                    dismissAfterPresentation = false
                    requestDismissal()
                }
            } else if !presenting, !completed {
                // No SwiftUI state reset on cancellation; the same host remains.
                phase = .presented
            } else {
                requestedPresentation = false
                phase = .idle
                dismissAfterPresentation = false
                host = nil
                pan = nil
                parent.isPresented = false
            }
        }

        func presentationController(forPresented presented: UIViewController, presenting: UIViewController?, source: UIViewController) -> UIPresentationController? {
            PlayerSurfacePresentationController(presentedViewController: presented, presenting: presenting)
        }

        func animationController(forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController) -> (any UIViewControllerAnimatedTransitioning)? {
            makeAnimator(presenting: true)
        }

        func animationController(forDismissed dismissed: UIViewController) -> (any UIViewControllerAnimatedTransitioning)? {
            makeAnimator(presenting: false)
        }

        private func makeAnimator(presenting: Bool) -> PlayerSurfaceAnimator {
            PlayerSurfaceAnimator(
                presenting: presenting,
                source: parent.context,
                reduceMotion: parent.reduceMotion,
                releaseVelocity: presenting ? 0 : releaseVelocity,
                completion: { [weak self] completed in
                    self?.transitionEnded(presenting: presenting, completed: completed)
                }
            )
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard phase == .presented, let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  let surface = host?.view else { return false }
            let velocity = pan.velocity(in: surface)
            guard velocity.y > 0, velocity.y > abs(velocity.x) * 1.15,
                  parent.context.permitsPan(at: pan.location(in: surface), in: surface) else { return false }
            // Inside a list (Queue), pulling down only dismisses from the top,
            // as in the reference; otherwise the list keeps its own scroll.
            if let scrollView = touchedScrollView {
                return scrollView.contentOffset.y <= -scrollView.adjustedContentInset.top + 0.5
            }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            // Fast public-type exclusion. Explicit app-owned exclusion markers
            // cover SwiftUI controls without traversing their private subviews.
            guard !(touch.view is UIControl), let surface = host?.view else { return false }
            touchedScrollView = Self.enclosingScrollView(of: touch.view, below: surface)
            return parent.context.permitsPan(at: touch.location(in: surface), in: surface)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            other === touchedScrollView?.panGestureRecognizer
        }

        /// Public UIKit superview walk; stops at the player surface.
        private static func enclosingScrollView(of view: UIView?, below surface: UIView) -> UIScrollView? {
            var current = view
            while let candidate = current, candidate !== surface {
                if let scrollView = candidate as? UIScrollView { return scrollView }
                current = candidate.superview
            }
            return nil
        }

        // The reference drag moves the whole full-size surface with the finger;
        // only after release does it morph into Mini. No transition runs while
        // dragging, so cancel is a plain spring back to identity.
        @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let host, let stableCoordinates = attachment?.view else { return }
            let surface = host.view!
            // Read movement in stationary coordinates; the surface itself is moving.
            let translation = max(0, recognizer.translation(in: stableCoordinates).y)
            switch recognizer.state {
            case .began:
                guard phase == .presented else { return }
                isDragging = true
                settleAnimator?.stopAnimation(true)
                if let scrollPan = touchedScrollView?.panGestureRecognizer {
                    // Hand the touch to the dismissal; toggling cancels the list's own pan.
                    scrollPan.isEnabled = false
                    scrollPan.isEnabled = true
                }
                surface.layer.cornerCurve = .continuous
                surface.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
                surface.clipsToBounds = true
            case .changed:
                guard isDragging else { return }
                surface.transform = CGAffineTransform(translationX: 0, y: translation)
                surface.layer.cornerRadius = min(PlayerSurfaceAnimator.displayCornerRadius, translation * 0.6)
                dimmingView?.alpha = PlayerSurfacePresentationController.dimAlpha * max(0, 1 - translation / surface.bounds.height)
            case .ended, .cancelled, .failed:
                guard isDragging else { return }
                isDragging = false
                let velocity = recognizer.velocity(in: stableCoordinates).y
                let travel = max(240, surface.bounds.height * 0.65)
                // App tuning values, not claimed Apple values. A deliberate
                // upward release cancels even past the distance gate.
                let finish = recognizer.state == .ended && velocity > -120
                    && (translation / travel >= 0.3 || velocity > 900)
                if finish {
                    releaseVelocity = velocity
                    phase = .dismissing
                    host.dismiss(animated: true)
                } else {
                    let distance = max(1, translation)
                    let animator = UIViewPropertyAnimator(duration: 0, timingParameters:
                        PlayerSurfaceAnimator.spring(velocity: -velocity / distance))
                    animator.addAnimations {
                        surface.transform = .identity
                        surface.layer.cornerRadius = 0
                        self.dimmingView?.alpha = PlayerSurfacePresentationController.dimAlpha
                    }
                    animator.addCompletion { [weak self] position in
                        guard position == .end, self?.isDragging == false else { return }
                        surface.clipsToBounds = false
                    }
                    settleAnimator = animator
                    animator.startAnimation()
                }
            default:
                break
            }
        }
    }
}

@MainActor
final class PlayerPresenterAttachment: UIViewController {
    var onReady: (() -> Void)?

    override func loadView() {
        view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        onReady?()
    }
}

@MainActor
/// The presented player. Its status bar is fixed here (light content over the always-dark player)
/// rather than read from SwiftUI preferences: UIKit updates the captured status bar as an alongside
/// animation of the presentation, and can run it while the first render inside `animateTransition`
/// is still creating UIKit-backed controls (`UISlider` init runs an animation block). Answering from
/// SwiftUI at that point re-entered the graph mid-update; with a `GeometryReader` whose content is
/// conditional, that evaluation created the progress slider a second time, and neither instance
/// received `updateUIView` again (a frozen position bar).
final class PlayerHostingController<Content: View>: UIHostingController<Content> {
    override var childForStatusBarStyle: UIViewController? { nil }
    override var childForStatusBarHidden: UIViewController? { nil }
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var prefersStatusBarHidden: Bool { false }
}

final class PlayerSurfacePresentationController: UIPresentationController {
    /// Reference recording: the uncovered browse page drops from luma 34 to 13
    /// (≈ black at 0.6) within ~170ms of opening, stays dimmed while a drag
    /// reveals it, and returns to full brightness as the card lands on Mini.
    static let dimAlpha: CGFloat = 0.6
    let dimmingView: UIView = {
        let view = UIView()
        view.backgroundColor = .black
        view.alpha = 0
        view.isUserInteractionEnabled = false
        return view
    }()

    override var frameOfPresentedViewInContainerView: CGRect { containerView?.bounds ?? .zero }
    override var shouldRemovePresentersView: Bool { false }

    override func presentationTransitionWillBegin() {
        super.presentationTransitionWillBegin()
        guard let containerView else { return }
        dimmingView.frame = containerView.bounds
        containerView.insertSubview(dimmingView, at: 0)
    }

    override func presentationTransitionDidEnd(_ completed: Bool) {
        super.presentationTransitionDidEnd(completed)
        if !completed { dimmingView.removeFromSuperview() }
    }

    override func dismissalTransitionDidEnd(_ completed: Bool) {
        super.dismissalTransitionDidEnd(completed)
        if completed { dimmingView.removeFromSuperview() }
    }

    override func containerViewWillLayoutSubviews() {
        super.containerViewWillLayoutSubviews()
        dimmingView.frame = containerView?.bounds ?? .zero
        // UIKit owns the full-screen container. No global window is involved.
        presentedView?.bounds.size = frameOfPresentedViewInContainerView.size
        presentedView?.center = CGPoint(x: frameOfPresentedViewInContainerView.midX,
                                       y: frameOfPresentedViewInContainerView.midY)
    }
}


/// Mini ↔ Full card morph. The whole player layout is scaled with the card
/// (as in the reference recording) rather than revealed at full size by a mask.
@MainActor
final class PlayerSurfaceAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    /// Rounding while the card is inset from the display edges; app tuning.
    static let displayCornerRadius: CGFloat = 44

    /// Fitted to the reference recording (card width 18/50/75/89% at 50ms
    /// steps): critically damped, ω ≈ 20.5 rad/s. Velocity is in the unit
    /// space described by UISpringTimingParameters.
    static func spring(velocity: CGFloat = 0) -> UISpringTimingParameters {
        UISpringTimingParameters(mass: 1, stiffness: 420, damping: 41,
                                 initialVelocity: CGVector(dx: velocity, dy: velocity))
    }

    private let presenting: Bool
    private let source: InteractivePlayerContext
    private let reduceMotion: Bool
    private let releaseVelocity: CGFloat
    private let completion: (Bool) -> Void

    init(presenting: Bool, source: InteractivePlayerContext, reduceMotion: Bool,
         releaseVelocity: CGFloat, completion: @escaping (Bool) -> Void) {
        self.presenting = presenting
        self.source = source
        self.reduceMotion = reduceMotion
        self.releaseVelocity = releaseVelocity
        self.completion = completion
    }

    func transitionDuration(using transitionContext: (any UIViewControllerContextTransitioning)?) -> TimeInterval {
        reduceMotion ? 0.2 : 0.5
    }

    func animateTransition(using transitionContext: any UIViewControllerContextTransitioning) {
        let container = transitionContext.containerView
        guard let surface = transitionContext.view(forKey: presenting ? .to : .from) else {
            transitionContext.completeTransition(false)
            completion(false)
            return
        }
        let full = container.bounds
        let dimming = (transitionContext.viewController(forKey: presenting ? .to : .from)?
            .presentationController as? PlayerSurfacePresentationController)?.dimmingView
        let originalAlpha = surface.alpha
        if presenting {
            surface.transform = .identity
            surface.frame = full
            // Invisible until the start transform is applied: the artwork
            // snapshot below commits a frame, which would flash the full player.
            surface.alpha = 0
            container.addSubview(surface)
            surface.layoutIfNeeded()
        }
        // A drag leaves the surface translated; start from where the finger left it.
        let dragOffset = presenting ? 0 : surface.transform.ty
        surface.layer.cornerRadius = 0
        surface.clipsToBounds = false

        guard !reduceMotion, let mini = source.sourceRect(in: container) else {
            surface.alpha = originalAlpha
            crossFade(surface, transitionContext)
            return
        }

        let startCard = presenting ? mini : full.offsetBy(dx: 0, dy: dragOffset)
        let endCard = presenting ? full : mini
        let miniRadius = min(22, mini.height / 2)
        let startRadius = presenting ? miniRadius : Self.displayCornerRadius
        let endRadius = presenting ? Self.displayCornerRadius : miniRadius

        // Measure artwork endpoints before transforming the surface.
        var temporaryViews: [UIView] = []
        var hiddenViews: [(UIView, CGFloat)] = []
        var artImage: UIImageView?
        var artEnd = CGRect.zero
        var artEndRadius: CGFloat = 0
        if let fullElement = source.elements[.fullArtwork], fullElement.fullyVisible,
           let fullArt = fullElement.view, let miniElement = source.elements[.miniArtwork],
           let miniArt = miniElement.view,
           fullArt.window === container.window, miniArt.window === container.window {
            let fullArtRect = fullArt.convert(fullArt.bounds, to: container)
            let miniArtRect = miniArt.convert(miniArt.bounds, to: container)
            if fullArtRect.width > 1, miniArtRect.width > 1,
               full.insetBy(dx: -1, dy: -1).contains(fullArtRect.offsetBy(dx: 0, dy: -dragOffset)),
               let image = snapshot(fullArt) {
                let view = UIImageView(image: image)
                view.contentMode = .scaleAspectFit
                view.clipsToBounds = true
                view.layer.cornerCurve = .continuous
                view.layer.cornerRadius = presenting ? miniElement.cornerRadius : fullElement.cornerRadius
                view.frame = presenting ? miniArtRect : fullArtRect
                artEnd = presenting ? fullArtRect : miniArtRect
                artEndRadius = presenting ? fullElement.cornerRadius : miniElement.cornerRadius
                artImage = view
                hiddenViews = [(fullArt, fullArt.alpha), (miniArt, miniArt.alpha)]
            }
        }

        // Mini's own title/controls ride the top of the card and hand over to
        // the player content. Snapshot the presenting hierarchy only, so the
        // player surface itself is never captured.
        var miniSnapshot: UIView?
        if let presentingView = transitionContext.viewController(forKey: presenting ? .from : .to)?.view,
           let snap = presentingView.resizableSnapshotView(from: presentingView.convert(mini, from: container),
                                                           afterScreenUpdates: false, withCapInsets: .zero) {
            snap.frame = CGRect(origin: startCard.origin, size: mini.size)
            snap.alpha = presenting ? 1 : 0
            snap.isUserInteractionEnabled = false
            miniSnapshot = snap
        }

        let originalMask = surface.mask
        let mask = UIView()
        mask.backgroundColor = .black
        mask.layer.cornerCurve = .continuous
        surface.mask = mask
        apply(card: startCard, radius: startRadius, to: surface, mask: mask, full: full)
        surface.alpha = originalAlpha

        if let miniSnapshot { container.addSubview(miniSnapshot); temporaryViews.append(miniSnapshot) }
        if let artImage { container.addSubview(artImage); temporaryViews.append(artImage) }
        for (view, _) in hiddenViews { view.alpha = 0 }

        let travel = max(1, abs(endCard.minY - startCard.minY))
        let animator = UIViewPropertyAnimator(duration: 0, timingParameters:
            Self.spring(velocity: presenting ? 0 : releaseVelocity / travel))
        animator.addAnimations { [presenting] in
            self.apply(card: endCard, radius: endRadius, to: surface, mask: mask, full: full)
            if !presenting { dimming?.alpha = 0 }
            artImage?.frame = artEnd
            artImage?.layer.cornerRadius = artEndRadius
            miniSnapshot?.frame.origin = endCard.origin
            UIView.animateKeyframes(withDuration: 0, delay: 0) {
                // Reference: Mini's label is gone by ~40% of the open; on close
                // it resolves in the last part of the contraction.
                UIView.addKeyframe(withRelativeStartTime: presenting ? 0 : 0.3,
                                   relativeDuration: presenting ? 0.15 : 0.25) {
                    miniSnapshot?.alpha = presenting ? 0 : 1
                }
            }
        }
        animator.addCompletion { [presenting, completion] _ in
            let completed = !transitionContext.transitionWasCancelled
            surface.transform = .identity
            surface.mask = originalMask
            for (view, alpha) in hiddenViews { view.alpha = alpha }
            for view in temporaryViews { view.removeFromSuperview() }
            if (presenting && !completed) || (!presenting && completed) {
                surface.removeFromSuperview()
            }
            transitionContext.completeTransition(completed)
            completion(completed)
        }
        animator.startAnimation()
        if presenting, let dimming {
            let fade = UIViewPropertyAnimator(duration: 0.17, curve: .easeOut) {
                dimming.alpha = PlayerSurfacePresentationController.dimAlpha
            }
            fade.startAnimation()
        }
    }

    /// Maps the full-size surface onto `card`: uniform scale from card width,
    /// top-left pinned, and a mask clipping the scaled layout to the card height.
    private func apply(card: CGRect, radius: CGFloat, to surface: UIView, mask: UIView, full: CGRect) {
        let scale = max(0.01, card.width / full.width)
        let tx = card.minX - (full.midX - full.width * scale / 2)
        let ty = card.minY - (full.midY - full.height * scale / 2)
        surface.transform = CGAffineTransform(translationX: tx, y: ty).scaledBy(x: scale, y: scale)
        mask.frame = CGRect(x: 0, y: 0, width: full.width, height: card.height / scale)
        mask.layer.cornerRadius = radius / scale
    }

    private func crossFade(_ surface: UIView, _ transitionContext: any UIViewControllerContextTransitioning) {
        let originalAlpha = surface.alpha
        if presenting { surface.alpha = 0 }
        let animator = UIViewPropertyAnimator(duration: transitionDuration(using: transitionContext), curve: .easeInOut)
        let dimming = (transitionContext.viewController(forKey: presenting ? .to : .from)?
            .presentationController as? PlayerSurfacePresentationController)?.dimmingView
        animator.addAnimations { [presenting] in
            surface.alpha = presenting ? originalAlpha : 0
            dimming?.alpha = presenting ? PlayerSurfacePresentationController.dimAlpha : 0
        }
        animator.addCompletion { [presenting, completion] _ in
            let completed = !transitionContext.transitionWasCancelled
            surface.alpha = originalAlpha
            surface.transform = .identity
            if (presenting && !completed) || (!presenting && completed) { surface.removeFromSuperview() }
            transitionContext.completeTransition(completed)
            completion(completed)
        }
        animator.startAnimation()
    }

    private func snapshot(_ view: UIView) -> UIImage? {
        guard view.bounds.width > 1, view.bounds.height > 1 else { return nil }
        view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds, format: format)
        var succeeded = false
        let image = renderer.image { _ in
            succeeded = view.drawHierarchy(in: view.bounds, afterScreenUpdates: presenting)
        }
        return succeeded ? image : nil
    }
}
