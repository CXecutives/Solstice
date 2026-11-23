/// Names a person can see, from host/brand.h: the same macros the C side builds its strings from.
enum Brand {
    static let name = SOLSTICE_NAME
    static let urlPrefix = SOLSTICE_URL_PREFIX
    static let agentBinary = SOLSTICE_AGENT_BINARY
    static let logFile = SOLSTICE_LOG_FILE
    static let logPrevFile = SOLSTICE_LOG_PREV_FILE
    static let nativeLogFile = SOLSTICE_NATIVE_LOG_FILE
    static let nativeLogPrevFile = SOLSTICE_NATIVE_LOG_PREV_FILE
    static let envFile = SOLSTICE_ENV_FILE
}
