import UIKit

/// The app's single full-screen image viewer, used for every image the app shows large:
/// a multi-image gallery, a direct-image post, or the upscaled RSS preview thumbnail.
///
/// There used to be two overlapping viewers — a zoomable one dismissed by tapping anywhere,
/// and a paged gallery one whose pages *presented the first on top of itself*. Two viewers
/// stacked with different dismiss gestures is why closing a zoomed gallery image took two
/// taps and sometimes dismissed by accident. Now there is one screen with one explicit
/// Close button.
///
/// Layout is an outer paging UIScrollView whose pages are each their own zooming
/// UIScrollView — the classic photo-browser arrangement, all UIScrollView APIs present since
/// iOS 2. (Nesting scroll views is fine on iOS 6; it's table/collection views inside a scroll
/// view that aren't.) Paging is disabled while a page is zoomed in, because the outer scroll
/// view would otherwise steal the pan and swiping would flick to the next image instead of
/// moving around the enlarged one — hence the "fit" button, which zooms back out and gives
/// the swipe back.
///
/// Memory is the binding constraint, not bandwidth: gallery entries are the ORIGINAL uploads
/// (measured 3840x2160 / ~6 MB JPEGs), which decode to ~33 MB of UIImage each. Loading a
/// 6-image gallery eagerly at full resolution needs ~200 MB — jetsam territory on a 512 MB
/// iPhone 4S, and UIImage(data:) simply starts returning nil under that pressure, which
/// looked like "the gallery won't load". Hence: downscale to screen size on decode, keep only
/// the visible page and its neighbours resident, and cap the cache by byte cost.
class ImageViewerVC: UIViewController, UIScrollViewDelegate {
    private let imageURLs: [String]
    /// Set instead of `imageURLs` when the caller already holds the only image there is (the
    /// RSS preview thumbnail blown up for posts with no full-size URL). Nothing to fetch.
    private let localImage: UIImage?

    private var pagingScroll: UIScrollView?
    private var pageScrolls: [UIScrollView] = []
    private var imageViews: [UIImageView] = []
    private var spinners: [UIActivityIndicatorView] = []
    private var pageControl: UIPageControl?
    private var fitButton: UIButton?

    /// URLs with a fetch in flight — pages get revisited constantly as the user swipes back
    /// and forth, and without this each revisit would start a duplicate download.
    private var loadingURLs = Set<String>()
    /// Pages kept in memory either side of the current one. 1 is enough to make a swipe feel
    /// instant while capping resident images at three.
    private static let pageWindow = 1
    private static let maxZoomScale: CGFloat = 4
    private static var imageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 12 * 1024 * 1024
        return cache
    }()

    init(imageURLs: [String]) {
        self.imageURLs = imageURLs
        self.localImage = nil
        super.init(nibName: nil, bundle: nil)
    }

    init(image: UIImage) {
        self.imageURLs = []
        self.localImage = image
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("not supported")
    }

    private var pageCount: Int {
        return localImage != nil ? 1 : imageURLs.count
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black

        let bounds = UIScreen.main.bounds
        let paging = UIScrollView(frame: bounds)
        paging.isPagingEnabled = true
        paging.delegate = self
        paging.showsHorizontalScrollIndicator = false
        paging.contentSize = CGSize(width: bounds.width * CGFloat(pageCount), height: bounds.height)
        view.addSubview(paging)
        pagingScroll = paging

        for index in 0..<pageCount {
            let page = UIScrollView(frame: CGRect(x: bounds.width * CGFloat(index), y: 0,
                                                  width: bounds.width, height: bounds.height))
            page.delegate = self
            page.minimumZoomScale = 1
            page.maximumZoomScale = ImageViewerVC.maxZoomScale
            page.showsHorizontalScrollIndicator = false
            page.showsVerticalScrollIndicator = false
            paging.addSubview(page)
            pageScrolls.append(page)

            let iv = UIImageView(frame: page.bounds)
            iv.contentMode = .scaleAspectFit
            iv.backgroundColor = UIColor.black
            iv.image = localImage
            page.addSubview(iv)
            imageViews.append(iv)

            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapZoom(_:)))
            doubleTap.numberOfTapsRequired = 2
            page.addGestureRecognizer(doubleTap)

            // Full-res gallery entries are multi-MB; without this a page is just black while
            // it downloads and looks broken rather than busy.
            let spinner = UIActivityIndicatorView(style: .white)
            spinner.center = CGPoint(x: page.bounds.midX, y: page.bounds.midY)
            spinner.hidesWhenStopped = true
            page.addSubview(spinner)
            spinners.append(spinner)
        }
        updateResidentPages()

        let close = makeIconButton(named: "icon-close", action: #selector(closeTapped))
        close.frame = CGRect(x: Layout.margin - 11, y: 20, width: 44, height: 44)
        view.addSubview(close)

        // Only meaningful once zoomed in — that's also the only time paging is off, so this
        // doubles as the way back to swiping through the gallery.
        let fit = makeIconButton(named: "icon-fit", action: #selector(fitTapped))
        fit.frame = CGRect(x: bounds.width - Layout.margin - 33, y: 20, width: 44, height: 44)
        fit.isHidden = true
        view.addSubview(fit)
        fitButton = fit

        if pageCount > 1 {
            let pc = UIPageControl(frame: CGRect(x: 0, y: bounds.height - 40, width: bounds.width, height: 20))
            pc.numberOfPages = pageCount
            pc.currentPage = 0
            pc.isUserInteractionEnabled = false
            view.addSubview(pc)
            pageControl = pc
        }
    }

    /// A white glyph on a translucent black disc: the icons have to stay legible over a
    /// photo, which may well be white where the button sits.
    private func makeIconButton(named: String, action: Selector) -> UIButton {
        let button = UIButton(type: .custom)
        button.setImage(UIImage(named: named), for: .normal)
        button.backgroundColor = UIColor(white: 0, alpha: 0.45)
        button.layer.cornerRadius = 22
        button.layer.masksToBounds = true
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    // MARK: - Zoom

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        guard let index = pageScrolls.firstIndex(where: { $0 === scrollView }) else { return nil }
        return imageViews[index]
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        guard scrollView !== pagingScroll else { return }
        syncZoomState()
    }

    /// Swiping is only possible at fit scale, so the two are driven together: paging off and
    /// the fit button shown exactly while the current page is zoomed in.
    private func syncZoomState() {
        let zoomed = currentPageScroll().map { $0.zoomScale > $0.minimumZoomScale } ?? false
        pagingScroll?.isScrollEnabled = !zoomed
        fitButton?.isHidden = !zoomed
    }

    private func currentPageScroll() -> UIScrollView? {
        let index = currentIndex()
        guard index >= 0, index < pageScrolls.count else { return nil }
        return pageScrolls[index]
    }

    @objc private func doubleTapZoom(_ recognizer: UITapGestureRecognizer) {
        guard let page = recognizer.view as? UIScrollView else { return }
        if page.zoomScale > page.minimumZoomScale {
            page.setZoomScale(page.minimumZoomScale, animated: true)
        } else {
            let point = recognizer.location(in: page)
            let side = page.bounds.width / ImageViewerVC.maxZoomScale
            page.zoom(to: CGRect(x: point.x - side / 2, y: point.y - side / 2,
                                 width: side, height: side), animated: true)
        }
    }

    @objc private func fitTapped() {
        currentPageScroll()?.setZoomScale(1, animated: true)
    }

    @objc private func closeTapped() {
        dismiss(animated: true, completion: nil)
    }

    // MARK: - Paging

    private func currentIndex() -> Int {
        guard let paging = pagingScroll, paging.bounds.width > 0 else { return 0 }
        return Int(round(paging.contentOffset.x / paging.bounds.width))
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // Also fires for each page's own zoom-panning, which has nothing to say about which
        // page is showing.
        guard scrollView === pagingScroll, scrollView.bounds.width > 0 else { return }
        let index = currentIndex()
        pageControl?.currentPage = index
        // A page left zoomed in would come back mid-image next time it's swiped to.
        for (other, page) in pageScrolls.enumerated() where other != index && page.zoomScale != 1 {
            page.zoomScale = 1
        }
        syncZoomState()
        updateResidentPages()
    }

    // MARK: - Image loading

    /// Loads the pages within `pageWindow` of the current one and releases the rest. Dropping
    /// `image` is what actually frees the pixels; the cache may still hold them, but under its
    /// own byte budget rather than one-per-page unbounded.
    private func updateResidentPages() {
        guard localImage == nil else { return }
        let current = currentIndex()
        for index in 0..<imageViews.count {
            if abs(index - current) <= ImageViewerVC.pageWindow {
                loadImage(at: index)
            } else {
                imageViews[index].image = nil
                spinners[index].stopAnimating()
            }
        }
    }

    private func loadImage(at index: Int) {
        let urlString = imageURLs[index]
        let imageView = imageViews[index]
        let spinner = spinners[index]
        if let cached = ImageViewerVC.imageCache.object(forKey: urlString as NSString) {
            imageView.image = cached
            spinner.stopAnimating()
            return
        }
        guard imageView.image == nil, !loadingURLs.contains(urlString),
              let url = URL(string: urlString) else { return }
        loadingURLs.insert(urlString)
        spinner.startAnimating()
        CurlFetcher.fetch(url: url, userAgent: RedditAPI.userAgent) { [weak self] data, error in
            guard let self = self else { return }
            self.loadingURLs.remove(urlString)
            spinner.stopAnimating()
            guard let data = data, let full = UIImage(data: data) else { return }
            let image = self.downscaled(full, toFit: UIScreen.main.bounds.size)
            ImageViewerVC.imageCache.setObject(image, forKey: urlString as NSString,
                                               cost: ImageViewerVC.byteCost(of: image))
            // The page may have scrolled out of the resident window while this was in flight;
            // assigning then would put back exactly the pixels updateResidentPages just freed.
            guard abs(index - self.currentIndex()) <= ImageViewerVC.pageWindow else { return }
            imageView.image = image
        }
    }

    /// Aspect-fit downscale to screen size. A 3840x2160 original costs ~33 MB decoded; at
    /// screen size it's ~1 MB, and the page is a scaleAspectFit view so nothing is lost
    /// visually. Same UIGraphicsBeginImageContextWithOptions approach as PostListVC's row
    /// thumbnails (safe since iOS 4).
    private func downscaled(_ image: UIImage, toFit size: CGSize) -> UIImage {
        guard image.size.width > 0, image.size.height > 0 else { return image }
        let ratio = min(size.width / image.size.width, size.height / image.size.height)
        guard ratio < 1 else { return image }
        let target = CGSize(width: floor(image.size.width * ratio), height: floor(image.size.height * ratio))
        UIGraphicsBeginImageContextWithOptions(target, false, 0)
        image.draw(in: CGRect(origin: .zero, size: target))
        let result = UIGraphicsGetImageFromCurrentImageContext() ?? image
        UIGraphicsEndImageContext()
        return result
    }

    private static func byteCost(of image: UIImage) -> Int {
        let pixels = image.size.width * image.scale * image.size.height * image.scale
        return Int(pixels) * 4
    }
}
