// 仅作文档模板，example.invalid 不是实际漫画服务。
// 使用时替换为有权访问的 API，并按实际验证结果填写 minAppVersion。
class ExampleSource extends ComicSource {
    name = "Example Source";
    key = "example_source";
    version = "1.0.0";
    minAppVersion = "2.2.1";
    url = "https://example.invalid/sources/example.js";
    api = "https://example.invalid/api";

    async requestJson(path) {
        const response = await Network.get(this.api + path, {
            "Accept": "application/json"
        });
        if (response.status !== 200) {
            throw new Error("Example API returned HTTP " + response.status);
        }
        return JSON.parse(response.body);
    }

    search = {
        optionList: [],
        load: async (keyword, options, page) => {
            const data = await this.requestJson(
                "/search?q=" + encodeURIComponent(keyword) + "&page=" + page
            );
            return {
                comics: data.items.map(item => new Comic({
                    id: String(item.id),
                    title: item.title,
                    subtitle: item.author,
                    cover: item.cover,
                    tags: item.tags || []
                })),
                maxPage: data.totalPages
            };
        }
    };

    comic = {
        loadInfo: async id => {
            const data = await this.requestJson("/comics/" + encodeURIComponent(id));
            const chapters = {};
            for (const chapter of data.chapters) {
                // 新源使用稳定的非整数键，保留服务端给出的阅读顺序。
                chapters["ep_" + chapter.id] = chapter.title;
            }
            return new ComicDetails({
                title: data.title,
                subtitle: data.author,
                cover: data.cover,
                description: data.description,
                tags: { author: [data.author] },
                chapters: chapters,
                updateTime: data.updatedOn,
                url: "https://example.invalid/comics/" + encodeURIComponent(id)
            });
        },

        loadEp: async (comicId, epId) => {
            if (typeof epId !== "string" || !epId.startsWith("ep_")) {
                throw new Error("Unknown chapter");
            }
            const data = await this.requestJson(
                "/comics/" + encodeURIComponent(comicId) +
                "/chapters/" + encodeURIComponent(epId.slice(3))
            );
            return { images: data.images };
        },

        onImageLoad: (imageKey, comicId, epId, target) => ({
            url: imageKey,
            headers: { "Referer": "https://example.invalid/" }
        }),

        // 缩略图回调必须同步返回，不能声明为 async。
        onThumbnailLoad: imageKey => ({
            url: imageKey,
            headers: { "Referer": "https://example.invalid/" }
        }),

        onClickTag: (namespace, tag) => ({
            page: "search",
            attributes: { text: tag }
        })
    };
}
