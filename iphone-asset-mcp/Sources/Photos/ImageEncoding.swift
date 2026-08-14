import UIKit

enum ImageEncoding {

    /// 긴 변이 maxDimension 을 넘지 않도록 축소한 크기(확대는 하지 않는다).
    static func fit(_ size: CGSize, maxDimension: CGFloat) -> CGSize {
        let longest = max(size.width, size.height)
        guard longest > maxDimension, longest > 0 else { return size }
        let scale = maxDimension / longest
        return CGSize(width: max(1, (size.width * scale).rounded()),
                      height: max(1, (size.height * scale).rounded()))
    }

    /// 지정한 바이트 예산 안에 들어올 때까지 품질을 낮추고, 그래도 크면 해상도를 줄인다.
    /// 모델 컨텍스트에 base64 로 실려가므로 상한을 두는 편이 안전하다.
    static func jpeg(_ image: UIImage, quality: CGFloat, maxBytes: Int) -> Data? {
        var currentImage = image
        var currentQuality = min(max(quality, 0.1), 1.0)

        for _ in 0..<4 {
            guard var data = currentImage.jpegData(compressionQuality: currentQuality) else { return nil }
            while data.count > maxBytes && currentQuality > 0.32 {
                currentQuality -= 0.15
                guard let smaller = currentImage.jpegData(compressionQuality: currentQuality) else { break }
                data = smaller
            }
            if data.count <= maxBytes { return data }

            // 품질만으로 부족하면 해상도를 한 단계 낮춘다.
            let reduced = fit(currentImage.size, maxDimension: max(currentImage.size.width, currentImage.size.height) * 0.7)
            guard reduced != currentImage.size, reduced.width >= 64 else { return data }
            currentImage = redraw(currentImage, to: reduced)
            currentQuality = min(max(quality, 0.1), 1.0)
        }
        return currentImage.jpegData(compressionQuality: currentQuality)
    }

    static func redraw(_ image: UIImage, to size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    struct SheetItem {
        let label: String
        let image: UIImage?
        let caption: String?
    }

    /// 번호가 적힌 격자 이미지를 만든다. 여러 장을 훑을 때 장당 한 번씩
    /// 이미지를 실어보내는 것보다 훨씬 저렴하다.
    static func contactSheet(items: [SheetItem], columns: Int, cellSize: CGFloat) -> UIImage {
        let columns = max(1, columns)
        let rows = Int(ceil(Double(items.count) / Double(columns)))
        let padding: CGFloat = 8
        let labelHeight: CGFloat = 22

        let cellWidth = cellSize
        let cellHeight = cellSize + labelHeight
        let canvas = CGSize(width: CGFloat(columns) * (cellWidth + padding) + padding,
                            height: CGFloat(max(rows, 1)) * (cellHeight + padding) + padding)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true

        return UIGraphicsImageRenderer(size: canvas, format: format).image { context in
            UIColor(white: 0.10, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: canvas))

            for (offset, item) in items.enumerated() {
                let column = offset % columns
                let row = offset / columns
                let originX = padding + CGFloat(column) * (cellWidth + padding)
                let originY = padding + CGFloat(row) * (cellHeight + padding)
                let imageRect = CGRect(x: originX, y: originY, width: cellWidth, height: cellSize)

                UIColor(white: 0.18, alpha: 1).setFill()
                context.fill(imageRect)

                if let image = item.image {
                    // aspect fill 로 잘라 넣어 격자가 흐트러지지 않게 한다.
                    let scale = max(imageRect.width / image.size.width, imageRect.height / image.size.height)
                    let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                    let drawRect = CGRect(x: imageRect.midX - drawSize.width / 2,
                                          y: imageRect.midY - drawSize.height / 2,
                                          width: drawSize.width,
                                          height: drawSize.height)
                    context.cgContext.saveGState()
                    context.cgContext.clip(to: imageRect)
                    image.draw(in: drawRect)
                    context.cgContext.restoreGState()
                }

                draw(text: item.label,
                     in: CGRect(x: originX + 4, y: originY + 3, width: cellWidth - 8, height: 18),
                     size: 13,
                     weight: .bold,
                     color: .white,
                     background: UIColor(white: 0, alpha: 0.55))

                if let caption = item.caption {
                    draw(text: caption,
                         in: CGRect(x: originX, y: originY + cellSize + 3, width: cellWidth, height: labelHeight - 4),
                         size: 11,
                         weight: .regular,
                         color: UIColor(white: 0.75, alpha: 1),
                         background: nil)
                }
            }
        }
    }

    private static func draw(text: String,
                             in rect: CGRect,
                             size: CGFloat,
                             weight: UIFont.Weight,
                             color: UIColor,
                             background: UIColor?) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail

        var attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        if let background { attributes[.backgroundColor] = background }

        NSAttributedString(string: text, attributes: attributes).draw(in: rect)
    }
}
