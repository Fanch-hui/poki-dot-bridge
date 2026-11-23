import Foundation

enum PokiTransactionActivity {
    private static let words: Set<String> = [
        "支付", "付款", "购买", "購買", "下单", "下單", "确认支付", "確認支付", "提交订单", "提交訂單",
    ]
    private static let activity = try! NSRegularExpression(
        pattern: #"""
        (?x)
        (?:
            已(?:成功|完成|确认|確認)?
            | (?:最近|近期|近|过去|過去|已有|已经有|已經有)
              \s*(?:[0-9]+\s*(?:分钟|分鐘|小时|小時|天|周|週|月|年)\s*)?
              [0-9][0-9,.]*\s*[万萬千百]?\s*[+＋]?\s*(?:人|位(?:用户|用戶)?)\s*[+＋]?
            | (?:刚刚|剛剛|刚才|剛才)\s*有(?:用户|用戶)
        )\s*$
        """#
    )

    static func reports(_ text: String, word: String, range: Range<String.Index>) -> Bool {
        guard words.contains(word) else { return false }
        let prefix = String(text[..<range.lowerBound])
        if activity.firstMatch(in: prefix, range: NSRange(prefix.startIndex..., in: prefix)) != nil {
            return true
        }
        return isMerchantPromotion(text, word: word, range: range)
    }

    private static let navigationContext = [
        "进店", "進店",
        "店铺活动", "店鋪活動", "商家活动", "商家活動", "门店活动", "門店活動",
    ]
    private static let salesContext = ["月售", "已售", "销量", "銷量"]
    private static let serviceContext = ["起送", "配送", "运费", "運費"]
    private static let checkoutContext = [
        "应付", "應付", "实付", "實付", "待付", "还需支付", "還需支付",
        "合计", "合計", "总计", "總計", "总金额", "總金額", "订单金额", "訂單金額",
        "付款金额", "付款金額", "结算", "結算", "收银", "收銀",
        "确认订单", "確認訂單", "提交订单", "提交訂單",
    ]
    private static let promotionSuffixes = [
        "再减", "再減", "立减", "立減", "满减", "滿減", "后立减", "後立減", "后再减", "後再減",
        "享立减", "享立減", "享优惠", "享優惠", "优惠", "優惠", "返券", "返现", "返現", "领券", "領券",
        "后返券", "後返券", "后返现", "後返現", "享返券", "即返券", "宝红包", "寶紅包", "宝优惠", "寶優惠",
    ]
    private static let actionPrefixes = [
        "立即", "立刻", "马上", "馬上", "现在", "現在", "去", "确认", "確認", "点击", "點擊", "继续", "繼續", "提交",
        "请", "請", "先", "前往", "使用", "选择", "選擇",
    ]

    static func hasCheckoutContext(_ text: String) -> Bool {
        checkoutContext.contains(where: text.contains)
    }

    private static func hasMerchantContext(_ text: String) -> Bool {
        guard !hasCheckoutContext(text) else { return false }
        if navigationContext.contains(where: text.contains) { return true }
        let sales = salesContext.contains(where: text.contains)
        let service = serviceContext.contains(where: text.contains)
        return sales && service
    }

    private static func isMerchantPromotion(_ text: String, word: String, range: Range<String.Index>) -> Bool {
        guard ["支付", "付款", "购买", "購買"].contains(word),
              promotionSuffixes.contains(where: text[range.upperBound...].hasPrefix),
              hasMerchantContext(text) else { return false }
        let prefix = text[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let clause = prefix.split(whereSeparator: { ",，;；\n\r".contains($0) }).last ?? ""
        guard !["支付", "付款", "购买", "購買"].contains(where: clause.contains) else { return false }
        return !actionPrefixes.contains(where: { action in
            action == "去" ? clause.hasSuffix(action) : clause.contains(action)
        })
    }

    static func hasMerchantPromotion(_ text: String) -> Bool {
        for word in ["支付", "付款", "购买", "購買"] {
            var search = text.startIndex..<text.endIndex
            while let range = text.range(of: word, range: search) {
                if isMerchantPromotion(text, word: word, range: range) { return true }
                search = range.upperBound..<text.endIndex
            }
        }
        return false
    }

    static func isPromotionLabel(_ text: String) -> Bool {
        let label = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let word = ["支付", "付款", "购买", "購買"].first(where: label.hasPrefix) else { return false }
        let suffix = label.dropFirst(word.count)
        guard let promotion = promotionSuffixes.first(where: suffix.hasPrefix) else { return false }
        let amount = String(suffix.dropFirst(promotion.count))
        return amount.range(of: #"^[\s,:：，、]*[¥￥]?(?:[0-9]+(?:\.[0-9]+)?元?)?(?:优惠券|優惠券|券)?$"#, options: .regularExpression) != nil
    }
}

extension Computer {
    func reasonForPress(_ element: Element?, at point: (x: Double, y: Double)?, in scan: SensitiveScan, rules: SensitivityRules,
                        app: Foreground?, secureOnScreen: Bool) -> String? {
        let all = scan.allElements ?? scan.elements ?? lastAll
        let candidates = sensitiveElements(element, at: point, in: all)
        for candidate in candidates {
            if let reason = rules.reason(touching: candidate, typing: false, app: app, secureOnScreen: secureOnScreen) {
                return reason
            }
        }
        return nil
    }

    private func sensitiveElements(_ target: Element?, at point: (x: Double, y: Double)?, in all: [Element]) -> [Element?] {
        guard let target, !target.fromPicture else { return [target] }
        let actionTypes: Set<String> = ["Button", "Link"]
        let merchantCard = target.type == "Other" && PokiTransactionActivity.hasMerchantPromotion(target.text)
        let nestedAtPoint = all.last(where: { element in
            guard let point, actionTypes.contains(element.type), target.contains(element) else { return false }
            let frame = element.frame
            return frame.x <= point.x && point.x < frame.maxX && frame.y <= point.y && point.y < frame.maxY
        })
        let actionControl = nestedAtPoint ?? all.last(where: {
            actionTypes.contains($0.type) && ($0.node == target.node || $0.contains(target)) &&
                $0.frame.intersects(target.frame)
        })
        guard let control = actionControl ?? (merchantCard ? target : nil) else { return [target] }

        let nestedControls = all.filter { actionTypes.contains($0.type) && control.contains($0) }
        let children = all.filter { element in
            (element.type == "StaticText" || element.type == "Text") &&
                control.contains(element) && control.frame.intersects(element.frame) &&
                !nestedControls.contains(where: { $0.contains(element) })
        }
        let checkoutLabels = children.map(\.text).filter(PokiTransactionActivity.hasCheckoutContext)
        var classifiedControl = control
        if !checkoutLabels.isEmpty {
            classifiedControl.label = ([control.label].compactMap { $0 } + checkoutLabels).joined(separator: " ")
        }
        let hasPromotion = PokiTransactionActivity.hasMerchantPromotion(classifiedControl.text)
        func isPromotionChild(_ element: Element) -> Bool {
            (element.type == "StaticText" || element.type == "Text") &&
                control.contains(element) && hasPromotion &&
                PokiTransactionActivity.isPromotionLabel(element.text)
        }
        let labels = children.filter { !isPromotionChild($0) }
        return [target, classifiedControl].filter { !isPromotionChild($0) } + labels.map(Optional.some)
    }
}
