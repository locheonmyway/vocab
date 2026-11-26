# 知识发行维护

App 与知识共用一个源码仓库、分别编号：
`v2.2.0` 等 App 版本；`knowledge-v1.1.0` 等正式知识 Release。
App 内置正式目录；独立知识更新只读取固定 GitHub 仓库的清单和 Release 资产。

候选目录、外部原始内容、私人记录及审查材料留在仓库以外。每次候选通过内容、版权与来源审核之后，才加入 `knowledge/KnowledgeCatalog.json`。保留已有 ID、目标、核心情境及互动合同；不改变历史证据含义。全量目录用来避免多级补丁。更新前增加 `releaseSequence`，填写新的 `releaseVersion`。

发行：

1. 保存新的完整目录，并从上次正式 tag 导出上一版到临时文件，用 `python3 tools/prepare_knowledge.py --previous /path/to/previous.json` 检查并产生清单。
2. 本机 build、`--distribution-test` 和完整回归；审查 Git 实际待发布文件，不包含候选/记录/私有来源原件。
3. 提交正式目录，暂不推送新的 `knowledge/latest.json` 指针。创建独立版本 tag、推送并创建 Release，上传同一份 `KnowledgeCatalog.json`，不要设为最新 App Release。
4. 验证公开 Release 资产 SHA-256 与清单一致；最后提交并推送新的 `knowledge/latest.json`。
5. 自己的 App 与其他安装者通过同一更新机制接收；无需重新安装应用。

不得将候选自动发布。已发布版本不可原地替换；修复用下一发行号。无权许可的材料不发布。知识更新失败保留 last-good；App 更新使用独立源码安装，符合同一签名及备份规则。
