import ComposableArchitecture
import Dependencies
import Foundation

extension BookDetailFeature {
    func reduceCatalogRefresh(into state: inout State, action: Action) -> Effect<Action> {
        switch action {
        case .reloadChapters:
            guard !state.isLoadingChapters, !state.isRefreshingChapters else { return .none }
            state.isLoadingChapters = true
            state.chapterErrorMessage = nil
            let bookPath = state.detail.bookPath
            let loader = chapterListLoader
            return .run { send in
                do {
                    let chapters = try await loader.load(bookPath)
                    await send(.chaptersLoaded(chapters))
                } catch {
                    await send(.chaptersFailed(error.localizedDescription))
                }
            }

        case .refreshChapters:
            return refreshCatalog(into: &state)

        case let .chaptersRefreshed(chapters):
            state.isRefreshingChapters = false
            guard state.isOnShelf else { return .none }
            state.chapters = keepingCompletedDownloads(chapters, previous: state.chapters)
            state.detail.lastChapter = chapters.last?.name ?? state.detail.lastChapter
            state.chapterErrorMessage = nil
            state.catalogRefreshError = nil
            return .none

        case let .chapterRefreshFailed(message):
            state.isRefreshingChapters = false
            if state.isOnShelf {
                state.catalogRefreshError = message
            }
            return .none

        default:
            return .none
        }
    }

    private func refreshCatalog(into state: inout State) -> Effect<Action> {
        guard !state.isRefreshingChapters, !state.isLoadingChapters,
              !state.isLoading, !state.isPreviewLoading, !state.isShelfBusy else { return .none }
        guard state.isOnShelf else { return .send(.reloadPreview) }
        state.isRefreshingChapters = true
        state.catalogRefreshError = nil
        let bookPath = state.detail.bookPath
        @Dependency(\.chapterCatalogRefresher) var refresher
        let refresh = refresher.refresh
        return .run { send in
            do {
                let chapters = try await refresh(bookPath)
                await send(.chaptersRefreshed(chapters))
            } catch {
                await send(.chapterRefreshFailed(error.localizedDescription))
            }
        }
    }

    private func keepingCompletedDownloads(_ chapters: [ChapterItem], previous: [ChapterItem]) -> [ChapterItem] {
        let downloaded = Set(previous.filter(\.isDownloaded).map(\.path))
        return chapters.map { chapter in
            guard downloaded.contains(chapter.path), !chapter.isDownloaded else { return chapter }
            return ChapterItem(
                number: chapter.number,
                name: chapter.name,
                path: chapter.path,
                hasLocalText: true,
                isDownloaded: true
            )
        }
    }
}
