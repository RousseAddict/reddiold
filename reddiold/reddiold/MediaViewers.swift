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
class GalleryPagerVC: UIViewController, UIScrollViewDelegate {
    private let imageURLs: [String]
    private var pageControl: UIPageControl?
    private static var imageCache = NSCache<NSString, UIImage>()

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

        for (index, urlString) in imageURLs.enumerated() {
            let iv = UIImageView(frame: CGRect(x: bounds.width * CGFloat(index), y: 0,
                                                width: bounds.width, height: bounds.height))
            iv.contentMode = .scaleAspectFit
            iv.backgroundColor = UIColor.black
            iv.isUserInteractionEnabled = true
            iv.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(pageTapped(_:))))
            scroll.addSubview(iv)
            loadImage(urlString: urlString, into: iv)
        }

        let closeButton = UIButton(type: .custom)
        closeButton.frame = CGRect(x: 12, y: 28, width: 70, height: 32)
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

    private func loadImage(urlString: String, into imageView: UIImageView) {
        if let cached = GalleryPagerVC.imageCache.object(forKey: urlString as NSString) {
            imageView.image = cached
            return
        }
        guard let url = URL(string: urlString) else { return }
        CurlFetcher.fetch(url: url, userAgent: RedditAPI.userAgent) { data, error in
            guard let data = data, let image = UIImage(data: data) else { return }
            GalleryPagerVC.imageCache.setObject(image, forKey: urlString as NSString)
            imageView.image = image
        }
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
        guard let pc = pageControl, scrollView.bounds.width > 0 else { return }
        pc.currentPage = Int(round(scrollView.contentOffset.x / scrollView.bounds.width))
    }
}
