/// Provider-independent word classes for screenshot label composition. Phrases are parsed by grammar.
enum ScreenshotLexicon {
    static let identifierHeads: Set<String> = ["id", "no", "number", "num", "code", "ref", "reference", "rujukan", "#", "nombor"]
    static let nameHeads: Set<String> = ["name", "nama"]
    static let counterparties: Set<String> = ["merchant", "payee", "recipient", "receiver", "beneficiary", "biller", "to", "penerima", "peniaga", "kepada"]
    static let institutions: Set<String> = ["bank", "account", "card", "wallet", "from", "source", "akaun", "kad", "dari"]
    static let transactionQualifiers: Set<String> = ["transaction", "txn", "trx", "trans", "payment", "transfer", "receipt", "order", "invoice", "reference", "rujukan", "transaksi", "resit", "pembayaran"]
    static let authorizationQualifiers: Set<String> = ["approval", "auth", "authorisation", "authorization", "kelulusan"]
    static let nonTransactionQualifiers: Set<String> = ["merchant", "terminal", "mid", "tid", "account", "card", "customer", "member", "user", "phone", "mobile"]
    static let memoQualifiers: Set<String> = ["recipient", "recipients", "your", "beneficiary", "sender", "other", "details"]
    static let amountWords: Set<String> = ["amount", "total", "grand", "net", "paid", "pay", "payment", "jumlah", "bayaran", "amaun"]
    static let excludedAmounts: Set<String> = ["balance", "available", "limit", "fee", "charge", "cashback", "points", "reward", "discount", "saved", "change", "baki", "rebate", "tip"]
    static let dateWords: Set<String> = ["date", "time", "on", "tarikh", "masa", "waktu"]
    static let otherDateWords: Set<String> = ["posting", "posted", "due", "expiry", "valid", "statement", "next"]
    static let positiveStatus: Set<String> = ["successful", "success", "completed", "complete", "approved", "paid", "sent", "berjaya", "selesai"]
    static let negativeStatus: Set<String> = ["failed", "unsuccessful", "pending", "declined", "rejected", "reversed", "refunded", "processing", "cancelled", "gagal", "tidak", "proses"]
    static let incoming: Set<String> = ["refund", "refunded", "received", "credited", "reversal"]
    static let prePayment: Set<String> = ["confirm", "slide", "checkout", "proceed", "now", "sekarang", "bayar"]
    static let chrome: Set<String> = ["share", "done", "close", "back", "download", "save", "ok", "help", "report", "view"]
    static let typeCategory: Set<String> = ["type", "category", "kategori", "method", "channel"]
    static let rails: Set<String> = ["duitnow", "fpx", "jompay", "qr"]
    static let connectors: Set<String> = ["of", "and", "for", "the", "in", "at", "ke", "&"]
    static let neutral: Set<String> = ["service", "details", "memo", "note"]

    static let words: Set<String> = identifierHeads.union(nameHeads).union(counterparties).union(institutions)
        .union(transactionQualifiers).union(authorizationQualifiers).union(nonTransactionQualifiers)
        .union(memoQualifiers).union(amountWords).union(excludedAmounts).union(dateWords)
        .union(otherDateWords).union(positiveStatus).union(negativeStatus).union(incoming).union(prePayment)
        .union(chrome).union(typeCategory).union(rails).union(connectors).union(neutral)
}
