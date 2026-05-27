public enum StateTask {

    @TaskLocal
    public static var isBackground: Bool = false

    @TaskLocal
    static var currentActionKey: Int?
}
