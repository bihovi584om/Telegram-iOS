import Foundation
import SwiftSignalKit
import Postbox
import TelegramApi

public func canShareLinkToPeer(peer: EnginePeer) -> Bool {
    var isEnabled = false
    switch peer {
    case let .channel(channel):
        if channel.adminRights != nil && channel.hasPermission(.inviteMembers) {
            isEnabled = true
        } else if channel.username != nil {
            isEnabled = true
        }
    default:
        break
    }
    return isEnabled
}

public enum ExportChatFolderError {
    case generic
    case limitExceeded
}

public struct ExportedChatFolderLink: Equatable {
    public var title: String
    public var link: String
    public var peerIds: [EnginePeer.Id]
    public var isRevoked: Bool
    
    public init(
        title: String,
        link: String,
        peerIds: [EnginePeer.Id],
        isRevoked: Bool
    ) {
        self.title = title
        self.link = link
        self.peerIds = peerIds
        self.isRevoked = isRevoked
    }
}

public extension ExportedChatFolderLink {
    var slug: String {
        var slug = self.link
        if slug.hasPrefix("https://t.me/folder/") {
            slug = String(slug[slug.index(slug.startIndex, offsetBy: "https://t.me/folder/".count)...])
        }
        return slug
    }
}

func _internal_exportChatFolder(account: Account, filterId: Int32, title: String, peerIds: [PeerId]) -> Signal<ExportedChatFolderLink, ExportChatFolderError> {
    return account.postbox.transaction { transaction -> [Api.InputPeer] in
        return peerIds.compactMap(transaction.getPeer).compactMap(apiInputPeer)
    }
    |> castError(ExportChatFolderError.self)
    |> mapToSignal { inputPeers -> Signal<ExportedChatFolderLink, ExportChatFolderError> in
        return account.network.request(Api.functions.communities.exportCommunityInvite(community: .inputCommunityDialogFilter(filterId: filterId), title: title, peers: inputPeers))
        |> mapError { error -> ExportChatFolderError in
            if error.errorDescription == "INVITES_TOO_MUCH" {
                return .limitExceeded
            } else {
                return .generic
            }
        }
        |> mapToSignal { result -> Signal<ExportedChatFolderLink, ExportChatFolderError> in
            return account.postbox.transaction { transaction -> Signal<ExportedChatFolderLink, ExportChatFolderError> in
                switch result {
                case let .exportedCommunityInvite(filter, invite):
                    let parsedFilter = ChatListFilter(apiFilter: filter)
                    
                    let _ = updateChatListFiltersState(transaction: transaction, { state in
                        var state = state
                        if let index = state.filters.firstIndex(where: { $0.id == filterId }) {
                            state.filters[index] = parsedFilter
                        } else {
                            state.filters.append(parsedFilter)
                        }
                        state.remoteFilters = state.filters
                        return state
                    })
                    
                    switch invite {
                    case let .exportedCommunityInvite(flags, title, url, peers):
                        return .single(ExportedChatFolderLink(
                            title: title,
                            link: url,
                            peerIds: peers.map(\.peerId),
                            isRevoked: (flags & (1 << 0)) != 0
                        ))
                    }
                }
            }
            |> castError(ExportChatFolderError.self)
            |> switchToLatest
        }
    }
}

func _internal_getExportedChatFolderLinks(account: Account, id: Int32) -> Signal<[ExportedChatFolderLink]?, NoError> {
    return account.network.request(Api.functions.communities.getExportedInvites(community: .inputCommunityDialogFilter(filterId: id)))
    |> map(Optional.init)
    |> `catch` { _ -> Signal<Api.communities.ExportedInvites?, NoError> in
        return .single(nil)
    }
    |> mapToSignal { result -> Signal<[ExportedChatFolderLink]?, NoError> in
        guard let result = result else {
            return .single(nil)
        }
        return account.postbox.transaction { transaction -> [ExportedChatFolderLink]? in
            switch result {
            case let .exportedInvites(invites, chats, users):
                var peers: [Peer] = []
                var peerPresences: [PeerId: Api.User] = [:]
                
                for user in users {
                    let telegramUser = TelegramUser(user: user)
                    peers.append(telegramUser)
                    peerPresences[telegramUser.id] = user
                }
                for chat in chats {
                    if let peer = parseTelegramGroupOrChannel(chat: chat) {
                        peers.append(peer)
                    }
                }
                
                updatePeers(transaction: transaction, peers: peers, update: { _, updated -> Peer in
                    return updated
                })
                updatePeerPresences(transaction: transaction, accountPeerId: account.peerId, peerPresences: peerPresences)
                
                var result: [ExportedChatFolderLink] = []
                for invite in invites {
                    switch invite {
                    case let .exportedCommunityInvite(flags, title, url, peers):
                        result.append(ExportedChatFolderLink(
                            title: title,
                            link: url,
                            peerIds: peers.map(\.peerId),
                            isRevoked: (flags & (1 << 0)) != 0
                        ))
                    }
                }
                
                return result
            }
        }
    }
}

public enum EditChatFolderLinkError {
    case generic
}

func _internal_editChatFolderLink(account: Account, filterId: Int32, link: ExportedChatFolderLink, title: String?, peerIds: [EnginePeer.Id]?, revoke: Bool) -> Signal<ExportedChatFolderLink, EditChatFolderLinkError> {
    return account.postbox.transaction { transaction -> Signal<ExportedChatFolderLink, EditChatFolderLinkError> in
        var flags: Int32 = 0
        if revoke {
            flags |= 1 << 0
        }
        if title != nil {
            flags |= 1 << 1
        }
        var peers: [Api.InputPeer]?
        if let peerIds = peerIds {
            flags |= 1 << 2
            peers = peerIds.compactMap(transaction.getPeer).compactMap(apiInputPeer)
        }
        return account.network.request(Api.functions.communities.editExportedInvite(flags: flags, community: .inputCommunityDialogFilter(filterId: filterId), slug: link.slug, title: title, peers: peers))
        |> mapError { _ -> EditChatFolderLinkError in
            return .generic
        }
        |> map { result in
            switch result {
            case let .exportedCommunityInvite(flags, title, url, peers):
                return ExportedChatFolderLink(
                    title: title,
                    link: url,
                    peerIds: peers.map(\.peerId),
                    isRevoked: (flags & (1 << 0)) != 0
                )
            }
        }
    }
    |> castError(EditChatFolderLinkError.self)
    |> switchToLatest
    
}

public enum RevokeChatFolderLinkError {
    case generic
}

func _internal_deleteChatFolderLink(account: Account, filterId: Int32, link: ExportedChatFolderLink) -> Signal<Never, RevokeChatFolderLinkError> {
    return account.network.request(Api.functions.communities.deleteExportedInvite(community: .inputCommunityDialogFilter(filterId: filterId), slug: link.slug))
    |> mapError { error -> RevokeChatFolderLinkError in
        return .generic
    }
    |> ignoreValues
}

public enum CheckChatFolderLinkError {
    case generic
}

public final class ChatFolderLinkContents {
    public let localFilterId: Int32?
    public let title: String?
    public let peers: [EnginePeer]
    public let alreadyMemberPeerIds: Set<EnginePeer.Id>
    
    public init(
        localFilterId: Int32?,
        title: String?,
        peers: [EnginePeer],
        alreadyMemberPeerIds: Set<EnginePeer.Id>
    ) {
        self.localFilterId = localFilterId
        self.title = title
        self.peers = peers
        self.alreadyMemberPeerIds = alreadyMemberPeerIds
    }
}

func _internal_checkChatFolderLink(account: Account, slug: String) -> Signal<ChatFolderLinkContents, CheckChatFolderLinkError> {
    return account.network.request(Api.functions.communities.checkCommunityInvite(slug: slug))
    |> mapError { _ -> CheckChatFolderLinkError in
        return .generic
    }
    |> mapToSignal { result -> Signal<ChatFolderLinkContents, CheckChatFolderLinkError> in
        return account.postbox.transaction { transaction -> ChatFolderLinkContents in
            switch result {
            case let .communityInvite(title, peers, chats, users):
                var allPeers: [Peer] = []
                var peerPresences: [PeerId: Api.User] = [:]
                
                for user in users {
                    let telegramUser = TelegramUser(user: user)
                    allPeers.append(telegramUser)
                    peerPresences[telegramUser.id] = user
                }
                for chat in chats {
                    if let peer = parseTelegramGroupOrChannel(chat: chat) {
                        allPeers.append(peer)
                    }
                }
                
                updatePeers(transaction: transaction, peers: allPeers, update: { _, updated -> Peer in
                    return updated
                })
                updatePeerPresences(transaction: transaction, accountPeerId: account.peerId, peerPresences: peerPresences)
                
                var resultPeers: [EnginePeer] = []
                var alreadyMemberPeerIds = Set<EnginePeer.Id>()
                for peer in peers {
                    if let peerValue = transaction.getPeer(peer.peerId) {
                        resultPeers.append(EnginePeer(peerValue))
                        
                        if transaction.getPeerChatListIndex(peer.peerId) != nil {
                            alreadyMemberPeerIds.insert(peer.peerId)
                        }
                    }
                }
                alreadyMemberPeerIds.removeAll()
                
                return ChatFolderLinkContents(localFilterId: nil, title: title, peers: resultPeers, alreadyMemberPeerIds: alreadyMemberPeerIds)
            case let .communityInviteAlready(filterId, missingPeers, chats, users):
                var allPeers: [Peer] = []
                var peerPresences: [PeerId: Api.User] = [:]
                
                for user in users {
                    let telegramUser = TelegramUser(user: user)
                    allPeers.append(telegramUser)
                    peerPresences[telegramUser.id] = user
                }
                for chat in chats {
                    if let peer = parseTelegramGroupOrChannel(chat: chat) {
                        allPeers.append(peer)
                    }
                }
                
                updatePeers(transaction: transaction, peers: allPeers, update: { _, updated -> Peer in
                    return updated
                })
                updatePeerPresences(transaction: transaction, accountPeerId: account.peerId, peerPresences: peerPresences)
                
                let currentFilters = _internal_currentChatListFilters(transaction: transaction)
                var currentFilterTitle: String?
                var currentFilterPeers: [EnginePeer.Id] = []
                if let index = currentFilters.firstIndex(where: { $0.id == filterId }) {
                    switch currentFilters[index] {
                    case let .filter(_, title, _, data):
                        currentFilterTitle = title
                        currentFilterPeers = data.includePeers.peers
                    default:
                        break
                    }
                }
                
                var resultPeers: [EnginePeer] = []
                var alreadyMemberPeerIds = Set<EnginePeer.Id>()
                for peer in missingPeers {
                    if let peerValue = transaction.getPeer(peer.peerId) {
                        resultPeers.append(EnginePeer(peerValue))
                        
                        if transaction.getPeerChatListIndex(peer.peerId) != nil {
                            alreadyMemberPeerIds.insert(peer.peerId)
                        }
                    }
                }
                for peerId in currentFilterPeers {
                    if resultPeers.contains(where: { $0.id == peerId }) {
                        continue
                    }
                    if let peerValue = transaction.getPeer(peerId) {
                        if canShareLinkToPeer(peer: EnginePeer(peerValue)) {
                            resultPeers.append(EnginePeer(peerValue))
                            
                            if transaction.getPeerChatListIndex(peerId) != nil {
                                alreadyMemberPeerIds.insert(peerId)
                            }
                        }
                    }
                }
                
                return ChatFolderLinkContents(localFilterId: filterId, title: currentFilterTitle, peers: resultPeers, alreadyMemberPeerIds: alreadyMemberPeerIds)
            }
        }
        |> castError(CheckChatFolderLinkError.self)
    }
}

public enum JoinChatFolderLinkError {
    case generic
    case limitExceeded
}

func _internal_joinChatFolderLink(account: Account, slug: String, peerIds: [EnginePeer.Id]) -> Signal<Never, JoinChatFolderLinkError> {
    return account.postbox.transaction { transaction -> [Api.InputPeer] in
        return peerIds.compactMap(transaction.getPeer).compactMap(apiInputPeer)
    }
    |> castError(JoinChatFolderLinkError.self)
    |> mapToSignal { inputPeers -> Signal<Never, JoinChatFolderLinkError> in
        return account.network.request(Api.functions.communities.joinCommunityInvite(slug: slug, peers: inputPeers))
        |> mapError { error -> JoinChatFolderLinkError in
            if error.errorDescription == "DIALOG_FILTERS_TOO_MUCH" {
                return .limitExceeded
            } else {
                return .generic
            }
        }
        |> mapToSignal { result -> Signal<Never, JoinChatFolderLinkError> in
            account.stateManager.addUpdates(result)
            
            return .complete()
        }
    }
}

public final class ChatFolderUpdates {
    fileprivate let missingPeers: [Api.Peer]
    fileprivate let chats: [Api.Chat]
    fileprivate let users: [Api.User]
    
    public var availableChatsToJoin: Int {
        return self.missingPeers.count
    }
    
    fileprivate init(
        missingPeers: [Api.Peer],
        chats: [Api.Chat],
        users: [Api.User]
    ) {
        self.missingPeers = missingPeers
        self.chats = chats
        self.users = users
    }
}

func _internal_getChatFolderUpdates(account: Account, folderId: Int32) -> Signal<ChatFolderUpdates?, NoError> {
    return account.network.request(Api.functions.communities.getCommunityUpdates(community: .inputCommunityDialogFilter(filterId: folderId)))
    |> map(Optional.init)
    |> `catch` { _ -> Signal<Api.communities.CommunityUpdates?, NoError> in
        return .single(nil)
    }
    |> mapToSignal { result -> Signal<ChatFolderUpdates?, NoError> in
        guard let result = result else {
            return .single(nil)
        }
        switch result {
        case let .communityUpdates(missingPeers, chats, users):
            return .single(ChatFolderUpdates(missingPeers: missingPeers, chats: chats, users: users))
        }
    }
}

func _internal_joinAvailableChatsInFolder(account: Account, folderId: Int32, peerIds: [EnginePeer.Id]) -> Signal<Never, JoinChatFolderLinkError> {
    return account.postbox.transaction { transaction -> [Api.InputPeer] in
        return peerIds.compactMap(transaction.getPeer).compactMap(apiInputPeer)
    }
    |> castError(JoinChatFolderLinkError.self)
    |> mapToSignal { inputPeers -> Signal<Never, JoinChatFolderLinkError> in
        return account.network.request(Api.functions.communities.joinCommunityUpdates(community: .inputCommunityDialogFilter(filterId: folderId), peers: inputPeers))
        |> mapError { error -> JoinChatFolderLinkError in
            if error.errorDescription == "DIALOG_FILTERS_TOO_MUCH" {
                return .limitExceeded
            } else {
                return .generic
            }
        }
        |> mapToSignal { result -> Signal<Never, JoinChatFolderLinkError> in
            account.stateManager.addUpdates(result)
            
            return .complete()
        }
    }
}

func _internal_hideChatFolderUpdates(account: Account, folderId: Int32) -> Signal<Never, NoError> {
    return account.network.request(Api.functions.communities.hideCommunityUpdates(community: .inputCommunityDialogFilter(filterId: folderId)))
    |> `catch` { _ -> Signal<Api.Bool, NoError> in
        return .single(.boolFalse)
    }
    |> ignoreValues
}