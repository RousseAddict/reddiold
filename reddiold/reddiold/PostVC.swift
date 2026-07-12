import UIKit
import MediaPlayer

/// Post detail: title, subreddit/author/date, optional thumbnail (tap for full-size
/// preview), optional body/selftext, a "Show Comments" button that loads the flat
/// comment list on demand. All of this lives in the comments table's tableHeaderView so
/// long posts scroll naturally together with the comment list below — avoids needing a
/// second nested scroll container (never safe on iOS 6 anyway).
class PostVC: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let post: Post
    private var comments: [Comment] = []
    private var tableView: UITableView?
    private var thumbnailView: UIImageView?
    private var mediaBadgeLabel: UILabel?
    private var commentsButton: UIButton?
    private var isLoadingGallery = false
    // Retained so it isn't deallocated mid-playback, and so the finish-notification
    // observer below can be torn down against the right object.
    private var activeMoviePlayerVC: MPMoviePlayerViewController?
    private let cellId = "CommentCell"

    private static let bodyFont = UIFont.systemFont(ofSize: 14)
    private static let authorFont = UIFont.systemFont(ofSize: 12)

    init(post: Post) {
        self.post = post
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Post"
        view.backgroundColor = UIColor.white
        updateSaveButton()
    }

    private func updateSaveButton() {
        let isSaved = SavedPostsStore.contains(post.id)
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: isSaved ? "Unsave" : "Save",
            style: .plain, target: self, action: #selector(toggleSave))
    }

    @objc private func toggleSave() {
        if SavedPostsStore.contains(post.id) {
            SavedPostsStore.remove(post.id)
        } else {
            SavedPostsStore.add(post)
            // Comments may already be loaded (user tapped Show Comments before Save) —
            // persist them right away rather than waiting for a future re-fetch.
            if !comments.isEmpty {
                SavedPostsStore.saveComments(comments, forPostId: post.id)
            }
        }
        updateSaveButton()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard tableView == nil else { return }
        setupUI()
        loadThumbnail()
    }

    private func setupUI() {
        // view.bounds already excludes the nav bar on real iOS 6 (classic nav-controller
        // layout) — do not use UIScreen.main.bounds here, it's the full physical screen.
        let bounds = view.bounds

        let table = UITableView(frame: CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height))
        table.dataSource = self
        table.delegate = self
        table.tableFooterView = UIView(frame: .zero)
        view.addSubview(table)
        tableView = table

        table.tableHeaderView = buildHeaderView(width: bounds.width)
        table.reloadData()  // force contentSize recompute for the tall header, otherwise the table can under-report its scrollable height on long posts and clip the comments button
    }

    private func buildHeaderView(width: CGFloat) -> UIView {
        let contentWidth = width - 24
        var y: CGFloat = 8

        let titleFont = UIFont.boldSystemFont(ofSize: 16)
        let titleHeight = measureHeight(text: post.title, font: titleFont, width: contentWidth, numberOfLines: 0)
        let titleLabel = UILabel(frame: CGRect(x: 12, y: y, width: contentWidth, height: titleHeight))
        titleLabel.numberOfLines = 0
        titleLabel.font = titleFont
        titleLabel.backgroundColor = UIColor.clear
        titleLabel.text = post.title
        y += titleHeight + 4

        var detail = "r/\(post.subreddit) - \(post.author)"
        if let createdAt = post.createdAt {
            detail += " - \(RelativeTime.string(from: createdAt))"
        }
        let detailHeight = measureHeight(text: detail, font: PostVC.authorFont, width: contentWidth, numberOfLines: 0)
        let detailLabel = UILabel(frame: CGRect(x: 12, y: y, width: contentWidth, height: detailHeight))
        detailLabel.numberOfLines = 0
        detailLabel.font = PostVC.authorFont
        detailLabel.textColor = UIColor.orange
        detailLabel.backgroundColor = UIColor.clear
        detailLabel.text = detail
        y += detailHeight + 12

        var linkLabel: UILabel?
        if post.mediaKind == .other, let linkURLString = post.linkURL {
            let linkFont = PostVC.authorFont
            let linkHeight = measureHeight(text: linkURLString, font: linkFont, width: contentWidth, numberOfLines: 2)
            let label = UILabel(frame: CGRect(x: 12, y: y, width: contentWidth, height: linkHeight))
            label.numberOfLines = 2
            label.font = linkFont
            label.backgroundColor = UIColor.clear
            let attributed = NSMutableAttributedString(string: linkURLString)
            attributed.addAttribute(.foregroundColor, value: UIColor.blue, range: NSRange(location: 0, length: linkURLString.count))
            attributed.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: linkURLString.count))
            label.attributedText = attributed
            label.isUserInteractionEnabled = true
            label.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(linkTapped)))
            linkLabel = label
            y += linkHeight + 12
        }

        var imageView: UIImageView?
        var mediaBadge: UILabel?
        if post.displayableThumbnailURL != nil {
            let iv = UIImageView(frame: CGRect(x: 12, y: y, width: contentWidth, height: 140))
            iv.contentMode = .scaleAspectFit
            iv.backgroundColor = UIColor(white: 0.92, alpha: 1)
            iv.isUserInteractionEnabled = true
            iv.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(thumbnailTapped)))
            imageView = iv
            y += 140 + 12

            switch post.mediaKind {
            case .gallery:
                mediaBadge = makeMediaBadge(text: "Gallery - tap to view", over: iv.frame)
            case .video:
                mediaBadge = makeMediaBadge(text: "Play Video", over: iv.frame)
            case .other:
                break
            }
        }

        var bodyLabel: UILabel?
        if let body = post.displayableBodyText {
            let bodyHeight = measureHeight(text: body, font: PostVC.bodyFont, width: contentWidth, numberOfLines: 0)
            let label = UILabel(frame: CGRect(x: 12, y: y, width: contentWidth, height: bodyHeight))
            label.numberOfLines = 0
            label.font = PostVC.bodyFont
            label.textColor = UIColor.black
            label.backgroundColor = UIColor.clear
            label.text = body
            bodyLabel = label
            y += bodyHeight + 12
        }

        let button = UIButton(type: .custom)
        button.frame = CGRect(x: 12, y: y, width: contentWidth, height: 44)
        button.backgroundColor = UIColor.orange
        button.setTitle("Show Comments", for: .normal)
        button.setTitleColor(UIColor.white, for: .normal)
        button.titleLabel?.font = UIFont.boldSystemFont(ofSize: 16)
        button.layer.cornerRadius = 8
        button.layer.masksToBounds = true
        button.addTarget(self, action: #selector(loadCommentsTapped), for: .touchUpInside)
        y += 44 + 12

        let header = UIView(frame: CGRect(x: 0, y: 0, width: width, height: y))
        header.addSubview(titleLabel)
        header.addSubview(detailLabel)
        if let ll = linkLabel { header.addSubview(ll) }
        if let iv = imageView { header.addSubview(iv) }
        if let badge = mediaBadge { header.addSubview(badge) }
        if let bl = bodyLabel { header.addSubview(bl) }
        header.addSubview(button)

        thumbnailView = imageView
        mediaBadgeLabel = mediaBadge
        commentsButton = button

        return header
    }

    // Semi-transparent overlay bar pinned to the bottom edge of the thumbnail, indicating
    // a gallery/video post's tap action. isUserInteractionEnabled = false so the tap
    // gesture on the imageView underneath still fires.
    private func makeMediaBadge(text: String, over imageFrame: CGRect) -> UILabel {
        let badge = UILabel(frame: CGRect(x: imageFrame.minX, y: imageFrame.maxY - 24,
                                           width: imageFrame.width, height: 24))
        badge.backgroundColor = UIColor(white: 0, alpha: 0.6)
        badge.textColor = UIColor.white
        badge.font = UIFont.boldSystemFont(ofSize: 13)
        badge.textAlignment = .center
        badge.text = text
        badge.isUserInteractionEnabled = false
        return badge
    }

    private func loadThumbnail() {
        guard let urlString = post.displayableThumbnailURL, let url = URL(string: urlString) else { return }
        CurlFetcher.fetch(url: url, userAgent: RedditAPI.userAgent) { [weak self] data, error in
            guard let self = self, let data = data, let image = UIImage(data: data) else { return }
            self.thumbnailView?.image = image
        }
    }

    @objc private func thumbnailTapped() {
        switch post.mediaKind {
        case .gallery:
            openGallery()
        case .video(let videoId):
            playVideo(videoId: videoId)
        case .other:
            showFullImage()
        }
    }

    private func showFullImage() {
        guard let image = thumbnailView?.image else { return }
        let preview = ImagePreviewVC(image: image)
        preview.modalPresentationStyle = .fullScreen
        present(preview, animated: true, completion: nil)
    }

    // openURL(_:) (not the iOS10+ open(_:options:completionHandler:)) is the oldest
    // universally-available way to hand a URL to Safari — safe on iOS 6/7/8 alike.
    @objc private func linkTapped() {
        guard let urlString = post.linkURL, let url = URL(string: urlString) else { return }
        UIApplication.shared.openURL(url)
    }

    // Gallery images are never in the RSS feed — only fetched (and only once, cached
    // after) when the user actually taps the gallery badge, to avoid extra requests
    // against Reddit's rate limiter on every post shown in the list.
    private func openGallery() {
        guard !isLoadingGallery else { return }
        isLoadingGallery = true
        mediaBadgeLabel?.text = "Loading gallery..."
        RedditAPI.fetchGalleryImageURLs(permalink: post.permalink) { [weak self] urls, error in
            guard let self = self else { return }
            self.isLoadingGallery = false
            guard error == nil, !urls.isEmpty else {
                self.mediaBadgeLabel?.text = "Gallery - couldn't load, tap to retry"
                return
            }
            self.mediaBadgeLabel?.text = "Gallery - tap to view"
            let pager = GalleryPagerVC(imageURLs: urls)
            pager.modalPresentationStyle = .fullScreen
            self.present(pager, animated: true, completion: nil)
        }
    }

    // No network call happens until this is tapped — the HLS URL is just built from the
    // "v.redd.it/{id}" link already parsed out of the RSS content, and the movie player
    // fetches the manifest/segments itself lazily once presented. Explicitly setting
    // movieSourceType to .streaming avoids MPMoviePlayerController misidentifying the
    // m3u8 as a progressive download; shouldAutoplay (default true) starts playback once
    // the manifest loads, so no manual play() call is needed (calling it immediately in
    // the present() completion is too early and isn't necessary).
    private func playVideo(videoId: String) {
        guard let url = URL(string: "https://v.redd.it/\(videoId)/HLSPlaylist.m3u8"),
              let playerVC = MPMoviePlayerViewController(contentURL: url) else { return }
        activeMoviePlayerVC = playerVC
        playerVC.moviePlayer.movieSourceType = .streaming
        playerVC.moviePlayer.scalingMode = .aspectFit
        NotificationCenter.default.addObserver(
            self, selector: #selector(moviePlaybackDidFinish(_:)),
            name: NSNotification.Name("MPMoviePlayerPlaybackDidFinishNotification"),
            object: playerVC.moviePlayer)
        present(playerVC, animated: true, completion: nil)
    }

    // MPMoviePlayerViewController dismisses itself automatically the moment its
    // moviePlayer posts this notification — including when the "finish" is actually an
    // immediate load/playback error (blocked request, unsupported stream, etc). That's
    // what makes a broken video look like "it opens then instantly closes" with nothing
    // shown. Surface the real reason instead of failing silently. Reason values: 0 =
    // played to the end, 1 = playback error, 2 = user tapped Done — only alert on 1.
    @objc private func moviePlaybackDidFinish(_ notification: Notification) {
        NotificationCenter.default.removeObserver(
            self, name: NSNotification.Name("MPMoviePlayerPlaybackDidFinishNotification"),
            object: notification.object)
        activeMoviePlayerVC = nil
        let reason = (notification.userInfo?["MPMoviePlayerPlaybackDidFinishReasonUserInfoKey"] as? NSNumber)?.intValue ?? -1
        guard reason == 1 else { return }
        let alert = UIAlertView(title: "Couldn't play video",
                                 message: "Reddit's video stream failed to load (blocked request, network issue, or unsupported format).",
                                 delegate: nil, cancelButtonTitle: "OK")
        alert.show()
    }

    @objc private func loadCommentsTapped() {
        commentsButton?.isEnabled = false
        commentsButton?.setTitle("Loading...", for: .normal)
        loadComments()
    }

    private func loadComments() {
        let parts = post.permalink.split(separator: "/").map(String.init)
        guard let rIdx = parts.firstIndex(of: "r"), rIdx + 1 < parts.count,
              let cIdx = parts.firstIndex(of: "comments"), cIdx + 1 < parts.count else {
            commentsButton?.setTitle("No comments link", for: .normal)
            return
        }

        RedditAPI.fetchComments(subreddit: parts[rIdx + 1], postId: parts[cIdx + 1]) { [weak self] comments, error in
            guard let self = self else { return }
            if let error = error, comments.isEmpty {
                // No network (or fetch failed) — fall back to this saved post's offline
                // comment snapshot if one was persisted from an earlier successful load.
                if let cached = SavedPostsStore.comments(forPostId: self.post.id), !cached.isEmpty {
                    self.comments = cached
                    self.commentsButton?.isHidden = true
                    self.tableView?.reloadData()
                    return
                }
                self.commentsButton?.isEnabled = true
                self.commentsButton?.setTitle(self.errorMessage(for: error), for: .normal)
                return
            }
            self.comments = comments
            self.commentsButton?.isHidden = true
            self.tableView?.reloadData()
            // Keep this saved post's offline comment snapshot in sync with the latest fetch.
            if SavedPostsStore.contains(self.post.id) {
                SavedPostsStore.saveComments(comments, forPostId: self.post.id)
            }
        }
    }

    // Same status-code messaging as PostListVC's feed error handling — the button itself
    // doubles as the retry control instead of a separate error label.
    private func errorMessage(for error: Error) -> String {
        let code = (error as NSError).code
        switch code {
        case 429: return "Rate limited, try again shortly - tap to retry"
        default: return "Couldn't load comments - tap to retry"
        }
    }

    private func measureHeight(text: String, font: UIFont, width: CGFloat, numberOfLines: Int) -> CGFloat {
        let label = UILabel()
        label.font = font
        label.numberOfLines = numberOfLines
        label.lineBreakMode = .byWordWrapping
        label.text = text
        return label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }

    private func rowHeight(for comment: Comment, width: CGFloat) -> CGFloat {
        let textWidth = width - 30
        let body = HTMLUtil.stripTags(comment.bodyHTML)
        let bodyHeight = measureHeight(text: body, font: PostVC.bodyFont, width: textWidth, numberOfLines: 0)
        return bodyHeight + PostVC.authorFont.lineHeight + 24
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return rowHeight(for: comments[indexPath.row], width: tableView.bounds.width)
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return comments.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: cellId) ?? UITableViewCell(style: .subtitle, reuseIdentifier: cellId)
        let comment = comments[indexPath.row]
        cell.textLabel?.text = HTMLUtil.stripTags(comment.bodyHTML)
        cell.textLabel?.font = PostVC.bodyFont
        cell.textLabel?.numberOfLines = 0
        var detail = comment.author
        if let createdAt = comment.createdAt {
            detail += " - \(RelativeTime.string(from: createdAt))"
        }
        cell.detailTextLabel?.text = detail
        cell.detailTextLabel?.font = PostVC.authorFont
        cell.detailTextLabel?.textColor = UIColor.orange
        return cell
    }
}

/// Full-screen image preview with pinch-to-zoom (and double-tap-to-zoom), single-tap
/// dismiss. UIScrollView + viewForZooming(in:) is the classic, pre-iOS7-safe zoom
/// pattern — no iOS7+ gesture APIs required.
private class ImagePreviewVC: UIViewController, UIScrollViewDelegate {
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
private class GalleryPagerVC: UIViewController, UIScrollViewDelegate {
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
