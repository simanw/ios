//
//  MessageViewController.swift
//  ios
//
//  Copyright © 2019 Tinode. All rights reserved.
//

import Foundation
import UIKit
import MessageKit
import MessageInputBar
import TinodeSDK

protocol MessageDisplayLogic: class {
    func updateTitleBar(icon: UIImage?, title: String?)
    func displayChatMessages(messages: [StoredMessage])
    func endRefresh()
}

class MessageViewController: MessageKit.MessagesViewController, MessageDisplayLogic {
    static let kAvatarSize: CGFloat = 30

    var topicName: String? {
        didSet {
            topicType = Tinode.topicTypeByName(name: self.topicName)
            // Needed in order to get sender's avatar and display name
            topic = Cache.getTinode().getTopic(topicName: topicName!) as? DefaultComTopic
        }
    }
    var topicType: TopicType?
    var myUID: String?
    var topic: DefaultComTopic?

    var messages: [MessageType] = []

    private var interactor: (MessageBusinessLogic & MessageDataStore)?
    private let refreshControl = UIRefreshControl()
    private var noteTimer: Timer? = nil

    init() {
        super.init(nibName: nil, bundle: nil)
        self.setup()
    }

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        self.setup()
    }

    private func setup() {
        myUID = Cache.getTinode().myUid

        let interactor = MessageInteractor()
        let presenter = MessagePresenter()
        interactor.presenter = presenter
        presenter.viewController = self

        self.interactor = interactor
    }

    private func configureLayout() {
        guard let layout = messagesCollectionView.collectionViewLayout as?
            MessagesCollectionViewFlowLayout else { return }

        layout.sectionInset = UIEdgeInsets(top: 1, left: 8, bottom: 1, right: 8)

        // Hide the outgoing avatar and adjust the label alignment to line up with the messages
        layout.setMessageOutgoingAvatarSize(.zero)
        layout.setMessageOutgoingMessageBottomLabelAlignment(LabelAlignment(textAlignment: .right, textInsets: UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 8)))

        // Set incoming avatar to overlap with the message bubble
        if topic!.isP2PType {
            layout.setMessageIncomingAvatarSize(.zero)
        } else {
            layout.setMessageIncomingAvatarSize(CGSize(width: MessageViewController.kAvatarSize, height: MessageViewController.kAvatarSize))
            layout.setMessageIncomingMessageBottomLabelAlignment(LabelAlignment(textAlignment: .left, textInsets: UIEdgeInsets(top: 0, left: MessageViewController.kAvatarSize + 8, bottom: 0, right: 0)))
            layout.setMessageIncomingMessagePadding(UIEdgeInsets(top: 0, left: -16, bottom: 0, right: 16))
        }
    }

    override func viewDidLoad() {
        messagesCollectionView = MessagesCollectionView(frame: .zero, collectionViewLayout: MessagesFlowLayout())
        super.viewDidLoad()

        messagesCollectionView.messagesDataSource = self
        messageInputBar.delegate = self

        reloadInputViews()
        scrollsToBottomOnKeyboardBeginsEditing = true
        maintainPositionOnKeyboardFrameChanged = true

        messagesCollectionView.addSubview(refreshControl)
        refreshControl.addTarget(self, action: #selector(loadNextPage), for: .valueChanged)

        configureLayout()

        messagesCollectionView.messagesLayoutDelegate = self
        messagesCollectionView.messagesDisplayDelegate = self
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        if !(self.interactor?.setup(topicName: self.topicName) ?? false) {
            print("error in interactor setup for \(String(describing: self.topicName))")
        }
        self.interactor?.attachToTopic()
        self.interactor?.loadMessages()
        self.noteTimer = Timer.scheduledTimer(
            withTimeInterval: 1,
            repeats: true,
            block: { _ in
                self.interactor?.sendReadNotification()
            })
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)

        self.interactor?.cleanup()
        self.noteTimer?.invalidate()
    }

    @objc func loadNextPage() {
        self.interactor?.loadNextPage()
    }
}

extension StoredMessage: MessageType {
    var sender: Sender {
        get {
            return Sender(
                id: self.from ?? "?",
                displayName: (self.from ?? "Unknown")) // This value is used only when the sender is not found.
        }
    }
    var messageId: String {
        get { return self.id ?? "?" }
    }
    var sentDate: Date {
        get { return self.ts ?? Date() }
    }
    var kind: MessageKind {
        get { return .text(self.content ?? "") }
    }
}

extension MessageViewController {
    func updateTitleBar(icon: UIImage?, title: String?) {
        self.navigationItem.title = title ?? "Undefined"

        let avatarView = AvatarView()
        NSLayoutConstraint.activate([
                avatarView.heightAnchor.constraint(equalToConstant: 32),
                avatarView.widthAnchor.constraint(equalTo: avatarView.heightAnchor)
            ])
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(customView: avatarView)
        avatarView.set(icon: icon, title: title, id: topicName)
   }

    func displayChatMessages(messages: [StoredMessage]) {
        self.messages = messages.reversed()
        self.messagesCollectionView.reloadData()
        // FIXME: don't scroll to bottom in response to loading the next page.
        // Maybe don't scroll to bottom if the view is not at the bottom already.
        self.messagesCollectionView.scrollToBottom()
    }

    func endRefresh() {
        DispatchQueue.main.async {
            self.refreshControl.endRefreshing()
        }
    }
}

extension MessageViewController: MessagesDataSource {
    func currentSender() -> Sender {
        return Sender(id: myUID ?? "???", displayName: "")
    }
    func numberOfSections(in messagesCollectionView: MessagesCollectionView) -> Int {
        return messages.count
    }
    func messageForItem(at indexPath: IndexPath, in messagesCollectionView: MessagesCollectionView) -> MessageType {
        return messages[indexPath.section]
    }

    func isTimeLabelVisible(at indexPath: IndexPath) -> Bool {
        return !isPreviousMessageSameDate(at: indexPath)
    }

    func cellTopLabelAttributedText(for message: MessageType, at indexPath: IndexPath) -> NSAttributedString? {
        if isTimeLabelVisible(at: indexPath) {
            // FIXME: This is not great. This should be moved to UiUtils.
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            return NSAttributedString(string: formatter.string(from: message.sentDate), attributes: [NSAttributedString.Key.font: UIFont.boldSystemFont(ofSize: 10), NSAttributedString.Key.foregroundColor: UIColor.darkGray])
        }
        return nil
    }

    func messageBottomLabelAttributedText(for message: MessageType, at indexPath: IndexPath) -> NSAttributedString? {
        guard topic!.isGrpType && (!isNextMessageSameSender(at: indexPath) || !isNextMessageSameDate(at: indexPath))  else { return nil }

        var displayName = message.sender.displayName
        if let sub = topic?.getSubscription(for: message.sender.id) {
            displayName = sub.pub!.fn!
        }
        // FIXME: create a static formatter in UiUtils. Don't create a new one every time.
        // The formatter included in MessageKit is not flexible enough.
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        let timestamp = formatter.string(from: message.sentDate)
        let label = isFromCurrentSender(message: message) ? "delivered" : "\(displayName), \(timestamp)"

        return NSAttributedString(string: label, attributes: [
            NSAttributedString.Key.font: UIFont.preferredFont(forTextStyle: .caption2),
            NSAttributedString.Key.foregroundColor: UIColor.gray
            ])
    }
}

extension MessageViewController: MessagesDisplayDelegate, MessagesLayoutDelegate {
    // Helper checks.

    func isPreviousMessageSameDate(at indexPath: IndexPath) -> Bool {
        guard indexPath.section > 0 else { return false }
        return Calendar.current.isDate(messages[indexPath.section].sentDate,
                                       inSameDayAs: messages[indexPath.section - 1].sentDate)
    }

    func isNextMessageSameDate(at indexPath: IndexPath) -> Bool {
        guard indexPath.section + 1 < messages.count else { return false }
        return Calendar.current.isDate(messages[indexPath.section].sentDate,
                                       inSameDayAs: messages[indexPath.section + 1].sentDate)
    }

    func isPreviousMessageSameSender(at indexPath: IndexPath) -> Bool {
        guard indexPath.section > 0 else { return false }
        return messages[indexPath.section].sender == messages[indexPath.section - 1].sender
    }

    func isNextMessageSameSender(at indexPath: IndexPath) -> Bool {
        guard indexPath.section + 1 < messages.count else { return false }
        return messages[indexPath.section].sender == messages[indexPath.section + 1].sender
    }

    func configureAvatarView(_ avatarView: AvatarView, for message: MessageType, at indexPath: IndexPath, in messagesCollectionView: MessagesCollectionView) {
        // Hide current user's avatar as well as peer's avatar in p2p topics.
        // Avatars are useful in group topics only
        avatarView.isHidden = topic!.isP2PType || (isNextMessageSameSender(at: indexPath) && isNextMessageSameDate(at: indexPath))
        if let sub = topic?.getSubscription(for: message.sender.id) {
            avatarView.set(icon: sub.pub?.photo?.image(), title: sub.pub?.fn, id: message.sender.id)
        } else {
            print("subscription not found for \(message.sender.id)")
        }
    }

    func textColor(for message: MessageType, at indexPath: IndexPath, in messagesCollectionView: MessagesCollectionView) -> UIColor {
        return !isFromCurrentSender(message: message) ? .white : .darkText
    }
    func backgroundColor(for message: MessageType, at indexPath: IndexPath, in messagesCollectionView: MessagesCollectionView) -> UIColor {
        return !isFromCurrentSender(message: message)
            ? UIColor(red: 69/255, green: 193/255, blue: 89/255, alpha: 1)
            : UIColor(red: 230/255, green: 230/255, blue: 230/255, alpha: 1)
    }

    func messageStyle(for message: MessageType, at indexPath: IndexPath, in messagesCollectionView: MessagesCollectionView) -> MessageStyle {

        var corners: UIRectCorner = []

        if isFromCurrentSender(message: message) {
            corners.formUnion(.topLeft)
            corners.formUnion(.bottomLeft)
            if !isPreviousMessageSameSender(at: indexPath) || !isPreviousMessageSameDate(at: indexPath) {
                corners.formUnion(.topRight)
            }
            if !isNextMessageSameSender(at: indexPath) || !isNextMessageSameDate(at: indexPath) {
                corners.formUnion(.bottomRight)
            }
        } else {
            corners.formUnion(.topRight)
            corners.formUnion(.bottomRight)
            if !isPreviousMessageSameSender(at: indexPath) || !isPreviousMessageSameDate(at: indexPath) {
                corners.formUnion(.topLeft)
            }
            if !isNextMessageSameSender(at: indexPath) || !isNextMessageSameSender(at: indexPath) {
                corners.formUnion(.bottomLeft)
            }
        }

        return .custom { view in
            let radius: CGFloat = 16
            let path = UIBezierPath(roundedRect: view.bounds, byRoundingCorners: corners, cornerRadii: CGSize(width: radius, height: radius))
            let mask = CAShapeLayer()
            mask.path = path.cgPath
            view.layer.mask = mask
        }
    }


    func cellTopLabelHeight(for message: MessageType, at indexPath: IndexPath, in messagesCollectionView: MessagesCollectionView) -> CGFloat {
        if isTimeLabelVisible(at: indexPath) {
            return 24
        }
        return 0
    }

    // This is the hight of the field with the sender's name (left) or delivery status (right).
    func messageBottomLabelHeight(for message: MessageType, at indexPath: IndexPath, in messagesCollectionView: MessagesCollectionView) -> CGFloat {
        return isNextMessageSameSender(at: indexPath) && isNextMessageSameDate(at: indexPath) ? 0 : 16
    }
}

extension MessageViewController: MessageInputBarDelegate {
    func messageInputBar(_ inputBar: MessageInputBar, didPressSendButtonWith text: String) {
        _ = interactor?.sendMessage(content: text)
        messageInputBar.inputTextView.text.removeAll()
        messageInputBar.invalidatePlugins()
    }

    func messageInputBar(_ inputBar: MessageInputBar, textViewTextDidChangeTo text: String) {
        // Use to send a typing indicator
    }

    func messageInputBar(_ inputBar: MessageInputBar, didChangeIntrinsicContentTo size: CGSize) {
        // Use to change any other subview insets
    }
}
