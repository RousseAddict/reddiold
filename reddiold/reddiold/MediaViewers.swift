import UIKit

/// Full-screen image preview with pinch-to-zoom (and double-tap-to-zoom), single-tap
/// dismiss. UIScrollView + viewForZooming(in:) is the classic, pre-iOS7-safe zoom
/// pattern — no iOS7+ gesture APIs required.
class ImagePreviewVC: UIViewController, UIScrollViewDelegate {
    private let image: UIImage
    private var scrollView: UIScrollView?
    private var imageView: UIImageView?

    init(image: UIImage) {
        self.image = image
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black

        let bounds = UIScreen.main.bounds
        let scroll = UIScrollView(frame: bounds)
        scroll.delegate = self
        scroll.minimumZoomScale = 1.0
        scroll.maximumZoomScale = 4.0
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        view.addSubview(scroll)
        scrollView = scroll

        let imgView = UIImageView(image: image)
        imgView.frame = bounds
        imgView.contentMode = .scaleAspectFit
        imgView.isUserInteractionEnabled = true
        scroll.addSubview(imgView)
        scroll.contentSize = bounds.size
        imageView = imgView

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapZoom))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(dismissPreview))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        scroll.addGestureRecognizer(singleTap)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        return imageView
    }

    @objc private func doubleTapZoom(_ recognizer: UITapGestureRecognizer) {
        guard let scroll = scrollView else { return }
        if scroll.zoomScale > scroll.minimumZoomScale {
            scroll.setZoomScale(scroll.minimumZoomScale, animated: true)
        } else {
            let point = recognizer.location(in: imageView)
            let zoomRect = CGRect(x: point.x - 50, y: point.y - 50, width: 100, height: 100)
            scroll.zoom(to: zoomRect, animated: true)
        }
    }

    @objc private func dismissPreview() {
        dismiss(animated: true, completion: nil)
    }
}

/// Full-screen horizontal-paging viewer for multi-image gallery posts. Each page is a
/// plain scaleAspectFit UIImageView (own image fetched via CurlFetcher, cached in-memory —
/// same NSCache pattern as PostListVC's row thumbnails); tapping a page pushes the existing
/// pinch-zoom ImagePreviewVC for that single image. UIScrollView + isPagingEnabled is the
/// classic pre-iOS7-safe carousel pattern (present since iOS 2) — no UICollectionView
/// needed, and this never nests a table/collection view inside the scroll view.
///
/// Memory is the binding constraint here, not bandwidth: gallery entries are the ORIGINAL
/// uploads (measured 3840x2160 / ~6 MB JPEGs), which decode to ~33 MB of UIImage each.
/// Loading a 6-image gallery eagerly at full resolution needs ~200 MB — jetsam territory on
/// a 512 MB iPhone 4S, and UIImage(data:) simply starts returning nil under that pressure,
/// which looked like "the gallery won't load". Hence: downscale to screen size on decode,
/// keep only the visible page and its neighbours resident, and cap the cache by byte cost.
class GalleryPagerVC: UIViewController, UIScrollViewDelegate {
    private let imageURLs: [String]
    private var pageControl: UIPageControl?
    private var scrollView: UIScrollView?
    private var imageViews: [UIImageView] = []
    private var spinners: [UIActivityIndicatorView] = []
    /// URLs with a fetch in flight — pages get revisited constantly as the user swipes back
    /// and forth, and without this each revisit would start a duplicate download.
    private var loadingURLs = Set<String>()
    /// Pages kept in memory either side of the current one. 1 is enough to make a swipe feel
    /// instant while capping resident images at three.
    private static let pageWindow = 1
    private static var imageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 12 * 1024 * 1024
        return cache
    }()

    init(imageURLs: [String]) {
        self.imageURLs = imageURLs
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black

        let bounds = UIScreen.main.bounds
        let scroll = UIScrollView(frame: bounds)
        scroll.isPagingEnabled = true
        scroll.delegate = self
        scroll.showsHorizontalScrollIndicator = false
        scroll.contentSize = CGSize(width: bounds.width * CGFloat(imageURLs.count), height: bounds.height)
        view.addSubview(scroll)
        scrollView = scroll

        for index in 0..<imageURLs.count {
            let iv = UIImageView(frame: CGRect(x: bounds.width * CGFloat(index), y: 0,
                                                width: bounds.width, height: bounds.height))
            iv.contentMode = .scaleAspectFit
            iv.backgroundColor = UIColor.black
            iv.isUserInteractionEnabled = true
            iv.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(pageTapped(_:))))
            scroll.addSubview(iv)
            imageViews.append(iv)

            // Full-res gallery entries are multi-MB; without this a page is just black while
            // it downloads and looks broken rather than busy.
            let spinner = UIActivityIndicatorView(style: .white)
            spinner.center = CGPoint(x: iv.frame.midX, y: iv.frame.midY)
            spinner.hidesWhenStopped = true
            scroll.addSubview(spinner)
            spinners.append(spinner)
        }
        updateResidentPages()

        let closeButton = UIButton(type: .custom)
        closeButton.frame = CGRect(x: Layout.margin, y: 28, width: 70, height: 32)
        closeButton.setTitle("Close", for: .normal)
        closeButton.setTitleColor(UIColor.white, for: .normal)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        view.addSubview(closeButton)

        if imageURLs.count > 1 {
            let pc = UIPageControl(frame: CGRect(x: 0, y: bounds.height - 40, width: bounds.width, height: 20))
            pc.numberOfPages = imageURLs.count
            pc.currentPage = 0
            pc.isUserInteractionEnabled = false
            view.addSubview(pc)
            pageControl = pc
        }
    }

    /// Loads the pages within `pageWindow` of the current one and releases the rest. Dropping
    /// `image` is what actually frees the pixels; the cache may still hold them, but under its
    /// own byte budget rather than one-per-page unbounded.
    private func updateResidentPages() {
        guard let scroll = scrollView, scroll.bounds.width > 0 else { return }
        let current = Int(round(scroll.contentOffset.x / scroll.bounds.width))
        for index in 0..<imageViews.count {
            if abs(index - current) <= GalleryPagerVC.pageWindow {
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
        if let cached = GalleryPagerVC.imageCache.object(forKey: urlString as NSString) {
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
            GalleryPagerVC.imageCache.setObject(image, forKey: urlString as NSString,
                                                cost: GalleryPagerVC.byteCost(of: image))
            // The page may have scrolled out of the resident window while this was in flight;
            // assigning then would put back exactly the pixels updateResidentPages just freed.
            guard self.isResident(index: index) else { return }
            imageView.image = image
        }
    }

    private func isResident(index: Int) -> Bool {
        guard let scroll = scrollView, scroll.bounds.width > 0 else { return true }
        let current = Int(round(scroll.contentOffset.x / scroll.bounds.width))
        return abs(index - current) <= GalleryPagerVC.pageWindow
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

    @objc private func pageTapped(_ recognizer: UITapGestureRecognizer) {
        guard let iv = recognizer.view as? UIImageView, let image = iv.image else { return }
        let preview = ImagePreviewVC(image: image)
        preview.modalPresentationStyle = .fullScreen
        present(preview, animated: true, completion: nil)
    }

    @objc private func closeTapped() {
        dismiss(animated: true, completion: nil)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView.bounds.width > 0 else { return }
        pageControl?.currentPage = Int(round(scrollView.contentOffset.x / scrollView.bounds.width))
        updateResidentPages()
    }
}
