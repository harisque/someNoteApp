import Foundation
#if canImport(Accelerate)
import Accelerate
#endif
#if canImport(PDFKit)
import PDFKit
#endif
public enum PromptMode:String,CaseIterable,Codable,Sendable{case ask}
public struct Citation:Codable,Hashable,Sendable,Identifiable{
 public let document:String
 public let page:Int?
 public let location:Int?
 public let length:Int?
 public let conceptID:String?
 public let documentID:UUID?
 public init(document:String,page:Int?=nil,location:Int?=nil,length:Int?=nil,conceptID:String?=nil,documentID:UUID?=nil){self.document=document;self.page=page;self.location=location;self.length=length;self.conceptID=conceptID;self.documentID=documentID}
 public var id:String{conceptID ?? "\(documentID?.uuidString ?? document)-\(location ?? 0)"}
 public var utf16Range:NSRange?{guard let location,let length else{return nil};return NSRange(location:location,length:length)}
}
public struct Passage:Codable,Hashable,Sendable{public let text:String;public let citation:Citation;public let score:Double;public init(text:String,citation:Citation,score:Double=0){self.text=text;self.citation=citation;self.score=score}}
/// Per-pass candidate counts for one hybrid retrieval. Ask publishes these in
/// its tool-status stream so the semantic ranking step is visible instead of
/// looking like a stall between "searching" and "reading sources".
public struct RetrievalStats:Hashable,Sendable{
 public let lexical:Int
 public let semantic:Int
 public let semanticAvailable:Bool
 /// Candidates surviving fusion (and its weak-tail prune) before prompt packing.
 public let fused:Int
 public init(lexical:Int,semantic:Int,semanticAvailable:Bool,fused:Int){self.lexical=lexical;self.semantic=semantic;self.semanticAvailable=semanticAvailable;self.fused=fused}
 public static let empty=RetrievalStats(lexical:0,semantic:0,semanticAvailable:false,fused:0)
}
public protocol DocumentEmbedder:Sendable{func embed(_ text:String)async throws->[Float]}
/// Exact prompt-token counting for Ask's budget packing. The app injects the
/// language model's real tokenizer so `makePrompt` measures evidence instead of
/// estimating from a characters-per-token ratio: the estimate under-counts dense
/// numeric/symbol content and non-ASCII text, so packed prompts could overflow
/// the adapter's hard `contextWindowTokens` guard. `nil` means "unavailable";
/// the packer then falls back to the conservative character estimate.
public protocol PromptTokenCounter:Sendable{func tokenCount(_ text:String)async->Int?}
public struct HashEmbedder:DocumentEmbedder{
 public init(dimensions:Int=256){}
 public func embed(_ text:String)async throws->[Float]{[]}
}
public enum DocumentKind:String,Sendable{case pdf,text,markdown,unknown}
/// Top-level directory a document lives in. `confidential` is seeded read-only from
/// the app bundle; `personal` holds user imports. Each category also contains a
/// permanent system "AI Notes" subfolder (see `DocumentAssistant.aiNotesFolderID`).
public enum DocumentCategory:String,Codable,CaseIterable,Sendable{case confidential,personal}
/// A folder within a category. `isSystem == true` marks the two permanent
/// "AI Notes" folders (one per category), which cannot be renamed or deleted.
/// User-created folders live under `personal` only. Persisted separately from the catalog.
public struct Folder:Identifiable,Codable,Hashable,Sendable{
 public let id:UUID;public var name:String;public let category:DocumentCategory;public var createdAt:Date;public var isSystem:Bool
 public init(name:String,category:DocumentCategory,id:UUID=UUID(),isSystem:Bool=false,createdAt:Date=Date()){self.id=id;self.name=name;self.category=category;self.isSystem=isSystem;self.createdAt=createdAt}
 private enum CodingKeys:String,CodingKey{case id,name,category,createdAt,isSystem}
 // Tolerant decoder: a legacy/interim `"aiNote"` category maps to `.personal`, and a
 // missing `isSystem`/`createdAt` gets a default, so one old folder can't fail the
 // whole `folders.json` decode.
 public init(from decoder:Decoder)throws{let c=try decoder.container(keyedBy:CodingKeys.self);id=try c.decode(UUID.self,forKey:.id);name=try c.decode(String.self,forKey:.name);createdAt=try c.decodeIfPresent(Date.self,forKey:.createdAt) ?? Date(timeIntervalSince1970:0);isSystem=try c.decodeIfPresent(Bool.self,forKey:.isSystem) ?? false
  let raw=try c.decodeIfPresent(String.self,forKey:.category);category=(raw == "confidential") ? .confidential : .personal}
}
public struct Document:Identifiable,Codable,Hashable,Sendable{
 public let id:UUID;public var name:String;public var text:String;public var indexedAt:Date?;public var sourceFile:String?;public var category:DocumentCategory;public var folderID:UUID?;public var isNote:Bool
 public init(name:String,text:String,sourceFile:String?=nil,category:DocumentCategory = .personal,folderID:UUID?=nil,isNote:Bool=false){id=UUID();self.name=name;self.text=text;indexedAt=nil;self.sourceFile=sourceFile;self.category=category;self.folderID=folderID;self.isNote=isNote}
 private enum CodingKeys:String,CodingKey{case id,name,text,indexedAt,sourceFile,category,folderID,isNote}
 // Tolerant decoder so older catalogs still load instead of failing the whole
 // `try? decode([Document].self)`. Category is read as a raw string: the interim
 // `"aiNote"` category becomes a Personal note; a legacy `isNote` bool (no category)
 // is honored; anything else defaults to a Personal, non-note document.
 public init(from decoder:Decoder)throws{let c=try decoder.container(keyedBy:CodingKeys.self);id=try c.decode(UUID.self,forKey:.id);name=try c.decode(String.self,forKey:.name);text=try c.decode(String.self,forKey:.text);indexedAt=try c.decodeIfPresent(Date.self,forKey:.indexedAt);sourceFile=try c.decodeIfPresent(String.self,forKey:.sourceFile);folderID=try c.decodeIfPresent(UUID.self,forKey:.folderID)
  let explicitNote=try c.decodeIfPresent(Bool.self,forKey:.isNote)
  switch try c.decodeIfPresent(String.self,forKey:.category){
   case "confidential": category = .confidential; isNote = explicitNote ?? false
   case "aiNote": category = .personal; isNote = explicitNote ?? true
   default: category = .personal; isNote = explicitNote ?? false }}
 public var kind:DocumentKind{if isNote{return .markdown};let ext=((sourceFile ?? name) as NSString).pathExtension.lowercased();switch ext{case "pdf":return .pdf;case "md","markdown":return .markdown;case "txt","text":return .text;default:return .unknown}}
}
public protocol LanguageModel{@available(macOS 10.15,iOS 13,*)func stream(prompt:String)->AsyncThrowingStream<String,Error>}
public struct IndexedChunk:Codable,Hashable,Sendable{public let id:UUID;public let documentID:UUID;public let document:String;public let text:String;public let page:Int?;public let location:Int;public init(id:UUID=UUID(),documentID:UUID,document:String,text:String,page:Int?,location:Int){self.id=id;self.documentID=documentID;self.document=document;self.text=text;self.page=page;self.location=location}}
@available(macOS 10.15,iOS 13,*)public actor DocumentAssistant{
 public internal(set)var documents:[Document]=[];public internal(set)var folders:[Folder]=[];public let model:LanguageModel;public let store:URL;
 /// UI navigation state, kept in a lightweight sidecar (`documentState.json`) rather
 /// than on `Document` so recording an open never rewrites the full-text catalog.
 /// `recents` is most-recent-first; `favorites` is in the order added. Both are
 /// pruned against live documents on save. Virtual only: they never change a
 /// document's `folderID`/`category`.
 public internal(set)var recents:[UUID]=[];public internal(set)var favorites:[UUID]=[]
 /// Internal (not private) so the deep-search extension in `DeepSearch.swift`
 /// can read and rebuild it; `private` members are invisible to same-type
 /// extensions in other files.
 var index:[IndexedChunk]=[]
 /// Embedding model used by deep search's semantic pass. `HashEmbedder` (the
 /// default) returns empty vectors, which deep search treats as "semantic
 /// unavailable" and answers with literal occurrences only.
 public let embedder:DocumentEmbedder
 /// Cached per-chunk embedding vectors, keyed by chunk id. Persisted in
 /// `embeddings.json` next to the catalog; loaded at init, grown lazily by
 /// `ensureChunkEmbeddings`, pruned when chunks disappear.
 var embeddings:[UUID:[Float]]=[:]
 /// Document ids with an in-flight background embedding job, so repeated
 /// ingestion triggers (e.g. rapid note saves) don't start duplicate work.
 var embeddingInFlight:Set<UUID>=[]
 /// Query vectors from recent questions, most recently used last. Follow-up and
 /// repeated questions skip the embedder entirely; bounded by
 /// ``Self.queryVectorCacheLimit`` so it can't grow with the question history.
 var queryVectorCache:[(key:String,vector:[Float])]=[]
 /// Optional future official source for Confidential docs (fetch/push). Nil for now;
 /// Confidential is seeded from the app bundle instead.
 public var confidentialSource:ConfidentialSource?
 /// Read-only structured-data assets under Confidential. Seeded from the app bundle,
 /// refreshed via an injected `dataLinkSource`, persisted in `dataLinks.json`.
 var dataLinks:[DataLink]=[]
 /// Most recent fetched series per data link, kept in memory (and on disk under
 /// `DataSnapshots/`) so summaries and figures survive relaunch without refetching.
 var dataSnapshots:[UUID:DataSnapshot]=[:]
 /// Optional live source for Data Links. Injected by the app; nil means refresh throws
 /// `.notConfigured` (see `UnconfiguredDataLinkSource`).
 public var dataLinkSource:DataLinkSource?
 nonisolated var foldersURL:URL{store.deletingLastPathComponent().appendingPathComponent("folders.json")}
 nonisolated var embeddingsURL:URL{store.deletingLastPathComponent().appendingPathComponent("embeddings.json")}
 nonisolated var documentStateURL:URL{store.deletingLastPathComponent().appendingPathComponent("documentState.json")}
 /// Deterministic ids for the two permanent "AI Notes" system folders, so note
 /// `folderID` references stay valid across launches even before persistence.
 nonisolated static let personalAINotesFolderID=UUID(uuidString:"00000000-0000-0000-0000-0000000000a1")!
 nonisolated static let confidentialAINotesFolderID=UUID(uuidString:"00000000-0000-0000-0000-0000000000c1")!
 nonisolated static func aiNotesFolderID(for c:DocumentCategory)->UUID{c == .confidential ? confidentialAINotesFolderID : personalAINotesFolderID}
 /// Total input-token ceiling for a composed prompt (mirrors the app's configured context window).
 let promptTokenBudget:Int
 /// Tokens reserved for the model's answer so input + output stay within the ceiling.
 let reservedAnswerTokens:Int
 /// Real tokenizer for token-accurate prompt packing; nil falls back to the
 /// character estimate (see ``PromptTokenCounter``).
 public let tokenCounter:PromptTokenCounter?
 public init(model:LanguageModel,store:URL,embedder:DocumentEmbedder=HashEmbedder(),legacyStore:URL?=nil,tokenCounter:PromptTokenCounter?=nil,promptTokenBudget:Int=4096,reservedAnswerTokens:Int=512) {
  self.model=model
  self.store=store
  self.embedder=embedder
  self.tokenCounter=tokenCounter
  self.promptTokenBudget=promptTokenBudget
  self.reservedAnswerTokens=reservedAnswerTokens
  if let data=try? Data(contentsOf:store),let saved=try? JSONDecoder().decode([Document].self,from:data) { documents=saved }
  else if !FileManager.default.fileExists(atPath:store.path),let legacyStore,
          let data=try? Data(contentsOf:legacyStore),let saved=try? JSONDecoder().decode([Document].self,from:data) { documents=saved }
  let foldersFile=store.deletingLastPathComponent().appendingPathComponent("folders.json")
  if let data=try? Data(contentsOf:foldersFile),let saved=try? JSONDecoder().decode([Folder].self,from:data) { folders=saved }
  // Ensure the two permanent AI Notes system folders exist, then file any note that
  // predates them into its category's AI Notes folder. In-memory and idempotent; the
  // system folders are recreated deterministically each launch.
  for c in DocumentCategory.allCases where !folders.contains(where:{ $0.id == Self.aiNotesFolderID(for:c) }) {
   folders.append(Folder(name:"AI Notes",category:c,id:Self.aiNotesFolderID(for:c),isSystem:true,createdAt:Date(timeIntervalSince1970:0)))
  }
  for i in documents.indices {
   if documents[i].isNote, documents[i].folderID == nil {
    documents[i].folderID = Self.aiNotesFolderID(for: documents[i].category)
   }
  }
  // Load persisted Data Links and their last snapshots so summaries/figures survive
  // relaunch without a refetch. Tolerant: a bad file simply leaves the state empty.
  let dataLinksFile=store.deletingLastPathComponent().appendingPathComponent("dataLinks.json")
  if let data=try? Data(contentsOf:dataLinksFile),let saved=try? JSONDecoder().decode([DataLink].self,from:data){ dataLinks=saved }
  let snapshotsDir=store.deletingLastPathComponent().appendingPathComponent("DataSnapshots",isDirectory:true)
  if let files=try? FileManager.default.contentsOfDirectory(at:snapshotsDir,includingPropertiesForKeys:nil,options:[.skipsHiddenFiles]){
   for file in files where file.pathExtension.lowercased()=="json"{
    if let data=try? Data(contentsOf:file),let snap=try? JSONDecoder().decode(DataSnapshot.self,from:data){ dataSnapshots[snap.linkID]=snap }
   }
  }
  // Legacy indexes used broken page segmentation and offsets. Rebuild from
  // preserved source text instead of trusting those unversioned records.
  // Load the persisted deep-search embedding cache (tolerant: a bad or missing
  // file simply leaves the cache empty). The URL is computed inline from `store`
  // (a nonisolated let): touching the nonisolated computed `embeddingsURL` here
  // would forbid subsequent access to isolated stored properties in this init.
  let embeddingsFile=store.deletingLastPathComponent().appendingPathComponent("embeddings.json")
  if let data=try? Data(contentsOf:embeddingsFile),let saved=try? JSONDecoder().decode([String:[Float]].self,from:data){
   for (key,vector) in saved { if let id=UUID(uuidString:key){ embeddings[id]=vector } }
  }
  // Load persisted UI navigation state (recents/favorites). Tolerant: a bad or
  // missing file simply leaves the lists empty. URL computed inline from `store`
  // for the same reason as the embeddings load above.
  let stateFile=store.deletingLastPathComponent().appendingPathComponent("documentState.json")
  if let data=try? Data(contentsOf:stateFile),let saved=try? JSONDecoder().decode(DocumentUIState.self,from:data){ recents=saved.recent;favorites=saved.favorites }
 }
 func persist()throws{
  index=documents.flatMap { Self.makeChunks(document:$0) }
  try FileManager.default.createDirectory(at:store.deletingLastPathComponent(),withIntermediateDirectories:true)
  try bundle().write(documents:documents,sections:index,dataLinks:dataLinks,summaries:dataLinkSummaries())
  try JSONEncoder().encode(documents).write(to:store,options:.atomic)
  try JSONEncoder().encode(index).write(to:store.deletingPathExtension().appendingPathExtension("index.json"),options:.atomic)
  try JSONEncoder().encode(folders).write(to:foldersURL,options:.atomic)
  try JSONEncoder().encode(dataLinks).write(to:dataLinksURL,options:.atomic)
  // Keep recents/favorites pruned of any ids removed by this mutation (e.g. a
  // delete). Best-effort: a failed sidecar write never fails the mutation.
  saveUIState()
 }
 public func deleteDocument(id:UUID)throws{if let d=documents.first(where:{$0.id==id}),d.category == .confidential,!d.isNote{throw DocumentError.confidentialReadOnly};let removed=documents.filter{$0.id==id};documents.removeAll{$0.id==id};let doomed=index.filter{$0.documentID==id}.map{$0.id};index.removeAll{$0.documentID==id};pruneEmbeddings(chunkIDs:doomed);removeSourceFiles(removed);try persist()}
 public func deleteDocuments(at o:IndexSet)throws{let targeted=documents.enumerated().filter{o.contains($0.offset)}.map{$0.element};if targeted.contains(where:{$0.category == .confidential && !$0.isNote}){throw DocumentError.confidentialReadOnly};let ids=targeted.map{$0.id};documents=documents.enumerated().filter{!o.contains($0.offset)}.map{$0.element};let doomed=index.filter{ids.contains($0.documentID)}.map{$0.id};index.removeAll{ids.contains($0.documentID)};pruneEmbeddings(chunkIDs:doomed);removeSourceFiles(targeted);try persist()}
 public func importDocument(url:URL,category:DocumentCategory = .personal,folderID:UUID?=nil)async throws{
  let s=url.startAccessingSecurityScopedResource();defer{if s{url.stopAccessingSecurityScopedResource()}}
  let t=try Self.extract(url)
  var d=Document(name:url.lastPathComponent,text:t,category:category,folderID:folderID);d.indexedAt=Date()
  let ext=url.pathExtension.lowercased()
  let fileName="\(d.id.uuidString)\(ext.isEmpty ? "" : "."+ext)"
  let sources=sourcesDirectory()
  try FileManager.default.createDirectory(at:sources,withIntermediateDirectories:true)
  let dest=sources.appendingPathComponent(fileName)
  if !FileManager.default.fileExists(atPath:dest.path){ try FileManager.default.copyItem(at:url,to:dest) }
  d.sourceFile=fileName
  documents.append(d);try await rebuildIndex(for:d);try persist()
  // Warm the semantic index in the background so Ask's hybrid retrieval and
  // Deep Search find this document's vectors without a lazy build later.
  startBackgroundEmbedding(for:d.id)
 }
 private static func extract(_ u:URL)throws->String{
  let e=u.pathExtension.lowercased()
  if e=="pdf" {
#if canImport(PDFKit)
   guard let p=PDFDocument(url:u) else { throw NSError(domain:"Document",code:1,userInfo:[NSLocalizedDescriptionKey:"Unreadable PDF"]) }
   return (0..<p.pageCount).compactMap { n in let s=(p.page(at:n)?.string ?? "").trimmingCharacters(in:.whitespacesAndNewlines); return s.isEmpty ? nil : "[Page \(n+1)]\n\(s)" }.joined(separator:"\n\n")
#else
   throw NSError(domain:"Document",code:1,userInfo:[NSLocalizedDescriptionKey:"PDFKit unavailable"])
#endif
  }
  guard ["txt","md","markdown","text"].contains(e) else { throw NSError(domain:"Document",code:1,userInfo:[NSLocalizedDescriptionKey:"Choose PDF, TXT, or Markdown"]) }
  return try String(contentsOf:u,encoding:.utf8)
 }
 public func rebuildIndex(for d:Document)async throws{
  index.removeAll { $0.documentID == d.id }
  index.append(contentsOf: Self.makeChunks(document: d))
  try persist()
 }

 /// Splits a document's text into `(page, range)` segments using the `[Page N]`
 /// markers that PDF extraction inserts. Texts without markers yield a single
 /// page-less segment covering everything. Shared by chunking (index offsets)
 /// and deep search (mapping a match offset back to its page number).
 static func pageRanges(of text:String)->[(Int?,NSRange)] {
  let source = text as NSString
  let full = NSRange(location:0,length:source.length)
  let regex = try? NSRegularExpression(pattern:#"(?m)^\[Page ([0-9]+)\][ \t]*\r?\n?"#)
  let markers = regex?.matches(in:text,range:full) ?? []
  var pageRanges:[(Int?,NSRange)]=[]
  if markers.isEmpty {
   pageRanges=[(nil,full)]
  } else {
   if let first=markers.first,first.range.location>0 {
    pageRanges.append((nil,NSRange(location:0,length:first.range.location)))
   }
   for (position,marker) in markers.enumerated() {
    let numberRange=marker.range(at:1)
    let page=Int(source.substring(with:numberRange))
    let start=NSMaxRange(marker.range)
    let end=position+1<markers.count ? markers[position+1].range.location : source.length
    if end>start { pageRanges.append((page,NSRange(location:start,length:end-start))) }
   }
  }
  return pageRanges
 }
 /// The page number containing a UTF-16 offset, per ``pageRanges(of:)``.
 static func page(for location:Int,in pageRanges:[(Int?,NSRange)])->Int? {
  for (page,range) in pageRanges where NSLocationInRange(location,range) { return page }
  return nil
 }

 /// Deterministic chunk id: two 64-bit FNV-1a mixes over different seeds of
 /// "(documentID, location, text)", formatted as a UUID string. `persist()`
 /// regenerates every chunk, so stable ids keep the chunk-id-keyed embedding
 /// cache valid across unrelated imports; editing a chunk changes its id and
 /// naturally invalidates the stale vector.
 static func chunkID(documentID:UUID,location:Int,text:String)->UUID{
  var h1:UInt64=0xcbf2_9ce4_8422_2325
  var h2:UInt64=0x1000_0000_01b3
  for b in "\(documentID.uuidString.lowercased())#\(location)#\(text)".utf8 {
   h1=(h1^UInt64(b))&*0x100_0000_01b3
   h2=(h2^UInt64(b))&*0x9E37_79B9_7F4A_7C15
  }
  h1^=h1>>33;h1&*=0xff51_afd7_ed55_8ccd;h1^=h1>>33
  h2^=h2>>33;h2&*=0xc4ce_b9fe_1a85_ec53;h2^=h2>>33
  let s=String(format:"%08X-%04X-%04X-%04X-%04X%08X",UInt32(h1>>32),UInt32((h1>>16)&0xffff),UInt32(h1&0xffff),UInt32(h2>>48),UInt32((h2>>32)&0xffff),UInt32(h2&0xffff_ffff))
  return UUID(uuidString:s)!
 }

 private static func makeChunks(document d:Document)->[IndexedChunk] {
  let source = d.text as NSString
  let pageRanges = Self.pageRanges(of: d.text)
  var chunks:[IndexedChunk]=[]
  for (page,pageRange) in pageRanges {
   var cursor=pageRange.location
   let pageEnd=NSMaxRange(pageRange)
   while cursor<pageEnd {
    while cursor<pageEnd,let scalar=UnicodeScalar(source.character(at:cursor)),CharacterSet.whitespacesAndNewlines.contains(scalar) { cursor += 1 }
    guard cursor<pageEnd else { break }
    var length=min(1000,pageEnd-cursor)
    if cursor+length<pageEnd {
     let search=NSRange(location:cursor+max(0,length-220),length:min(220,length))
     let boundary=source.rangeOfCharacter(from:.whitespacesAndNewlines,options:.backwards,range:search)
     if boundary.location != NSNotFound { length=max(1,boundary.location-cursor) }
    }
    let range=source.rangeOfComposedCharacterSequences(for:NSRange(location:cursor,length:length))
    let text=source.substring(with:range).trimmingCharacters(in:.whitespacesAndNewlines)
    if !text.isEmpty {
     chunks.append(IndexedChunk(id:Self.chunkID(documentID:d.id,location:range.location,text:text),documentID:d.id,document:d.name,text:text,page:page,location:range.location))
    }
    let next=NSMaxRange(range)
    cursor=next>=pageEnd ? pageEnd : max(cursor+1,next-120)
   }
  }
  return chunks
 }
 func bundle()->OKFBundle{OKFBundle(root:store.deletingLastPathComponent().appendingPathComponent("OKFBundle",isDirectory:true))}
 private func sourcesDirectory()->URL{store.deletingLastPathComponent().appendingPathComponent("Sources",isDirectory:true)}
 private func removeSourceFiles(_ docs:[Document]){for d in docs{guard let f=d.sourceFile else{continue};try? FileManager.default.removeItem(at:sourcesDirectory().appendingPathComponent(f))}}
 public func sourceURL(for id:UUID)->URL?{guard let doc=documents.first(where:{$0.id==id}),let f=doc.sourceFile else{return nil};let url=sourcesDirectory().appendingPathComponent(f);return FileManager.default.fileExists(atPath:url.path) ? url : nil}
 /// Hybrid retrieval: fuses the lexical scan with a cosine ranking over the
 /// cached chunk embeddings using Reciprocal Rank Fusion, so Ask surfaces both
 /// exact-wording hits and paraphrased/similar claims. Never triggers an
 /// embedding build — only already-cached vectors participate — so a question
 /// is never blocked behind indexing work. When the semantic side is empty
 /// (HashEmbedder, simulator, cold cache, or an embed that exceeded
 /// ``hybridSemanticEmbedTimeoutNanoseconds``) the result is exactly the
 /// lexical ranking.
 public func retrieve(_ q:String,limit:Int=6)async->[Passage]{
  await retrieveDetailed(q,limit:limit).passages
 }
 /// ``retrieve(_:limit:)`` plus per-pass candidate counts, so Ask can show the
 /// hybrid pipeline working (keyword scan, semantic ranking, fusion) instead of
 /// appearing to stall on the embedding step. `scope` restricts *both* passes to
 /// the given entity ids (documents and/or Data Links) before ranking, so a
 /// scoped question ranks the best matches inside its scope instead of filtering
 /// the top of an unscoped list down to almost nothing.
 func retrieveDetailed(_ q:String,limit:Int,scope:Set<UUID>?=nil)async->(passages:[Passage],stats:RetrievalStats){
  guard limit>0 else { return ([],.empty) }
  // Concurrent passes: the semantic side suspends on the embedder, which frees
  // the actor to run the lexical scan instead of serializing behind it.
  async let lexicalTask=lexicalPassages(q,scope:scope)
  async let semanticTask=semanticPassages(q,scope:scope)
  let lexical=await lexicalTask
  let semantic=await semanticTask
  guard !semantic.isEmpty else {
   let kept=Array(lexical.prefix(limit))
   return (kept,RetrievalStats(lexical:lexical.count,semantic:0,semanticAvailable:false,fused:lexical.count))
  }
  let fused=Self.pruneWeakFused(Self.fuseRRF(lexical:lexical,semantic:semantic))
  return (Array(fused.prefix(limit)),RetrievalStats(lexical:lexical.count,semantic:semantic.count,semanticAvailable:true,fused:fused.count))
 }
 /// The lexical scoring pass over document chunks and Data Link summaries.
 /// Scoring is IDF-weighted token *coverage* of the query rather than a raw
 /// matched-token count, so a long question can't flood the candidate list with
 /// chunks that happened to contain one common word. Runs entirely in memory:
 /// a section concept's body is exactly the trimmed chunk text `OKFBundle.write`
 /// persisted, so the per-chunk concept read the old pass did on every question
 /// was pure I/O overhead.
 func lexicalPassages(_ q:String,scope:Set<UUID>?=nil)async->[Passage]{
  if index.isEmpty { for d in documents { try? await rebuildIndex(for:d) } }
  let bundle=self.bundle()
  if !FileManager.default.fileExists(atPath:bundle.root.path) { try? bundle.write(documents:documents,sections:index,dataLinks:dataLinks,summaries:dataLinkSummaries()) }
  let tokens=Self.lexicalTokens(q)
  guard !tokens.isEmpty else { return [] }
  let phrase=q.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()

  // Single scan collecting matched tokens per candidate and the document
  // frequency of each token, which the IDF weights below are derived from.
  var chunkMatches:[(chunk:IndexedChunk,matched:Set<String>,phraseHit:Bool)]=[]
  var linkMatches:[(summary:String,link:DataLink,matched:Set<String>,phraseHit:Bool)]=[]
  var df:[String:Int]=[:]
  for c in index {
   if let scope,!scope.contains(c.documentID) { continue }
   let low=c.text.lowercased()
   var matched:Set<String>=[]
   for t in tokens where low.contains(t) { matched.insert(t) }
   let phraseHit = !phrase.isEmpty && low.contains(phrase)
   guard !matched.isEmpty || phraseHit else { continue }
   for t in matched { df[t,default:0] += 1 }
   chunkMatches.append((c,matched,phraseHit))
  }
  // Score Data Link concepts so Ask can surface and cite live structured data
  // alongside document sections. Each link contributes one compact summary passage
  // whose citation navigates to the Data Link (conceptID prefix `datalinks/`).
  let summaries=dataLinkSummaries()
  for link in dataLinks {
   if let scope,!scope.contains(link.id) { continue }
   let summaryText=summaries[link.id] ?? link.scopeDescription
   guard !summaryText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { continue }
   let haystack=(summaryText+" "+link.name+" "+link.symbol).lowercased()
   var matched:Set<String>=[]
   for t in tokens where haystack.contains(t) { matched.insert(t) }
   let phraseHit = !phrase.isEmpty && haystack.contains(phrase)
   guard !matched.isEmpty || phraseHit else { continue }
   for t in matched { df[t,default:0] += 1 }
   linkMatches.append((summaryText,link,matched,phraseHit))
  }

  let corpus=max(1,index.count+dataLinks.count)
  func weight(_ token:String)->Double{ log(1.0+Double(corpus)/Double(max(1,df[token] ?? 0))) }
  let totalWeight=tokens.reduce(0.0) { $0+weight($1) }
  guard totalWeight>0 else { return [] }

  struct Scored{let passage:Passage;let coverage:Double;let phraseHit:Bool}
  var scored:[Scored]=[]
  for m in chunkMatches {
   let coverage=m.matched.reduce(0.0) { $0+weight($1) }/totalWeight
   let score=coverage+(m.phraseHit ? Self.lexicalPhraseBonus : 0)
   scored.append(Scored(passage:makePassageInMemory(for:m.chunk,score:score),coverage:coverage,phraseHit:m.phraseHit))
  }
  for m in linkMatches {
   let coverage=m.matched.reduce(0.0) { $0+weight($1) }/totalWeight
   let score=coverage+(m.phraseHit ? Self.lexicalPhraseBonus : 0)
   let citation=Citation(document:m.link.name,page:nil,location:nil,length:m.summary.utf16.count,conceptID:"datalinks/\(m.link.id.uuidString.lowercased())",documentID:nil)
   scored.append(Scored(passage:Passage(text:m.summary,citation:citation,score:score),coverage:coverage,phraseHit:m.phraseHit))
  }
  scored.sort { $0.passage.score != $1.passage.score ? $0.passage.score > $1.passage.score : $0.passage.citation.id < $1.passage.citation.id }

  // Relevance floor, with a retention safety net so a terse question or a small
  // library still returns its best few candidates instead of nothing.
  var keep=Set<Int>()
  for (i,s) in scored.enumerated() where s.phraseHit || s.coverage >= Self.hybridLexicalCoverageFloor { keep.insert(i) }
  let retain=min(Self.lexicalMinRetained,scored.count)
  if keep.count<retain { for i in 0..<retain { keep.insert(i) } }
  let kept=scored.enumerated().compactMap { keep.contains($0.offset) ? $0.element.passage : nil }
  return Array(kept.prefix(Self.hybridLexicalCandidateLimit))
 }
 /// Query tokens for lexical scoring: lowercased, split on non-alphanumerics,
 /// with single characters and stopwords dropped and duplicates removed. Falls
 /// back to every token when a question is nothing but stopwords, so short
 /// natural-language queries still retrieve something.
 static func lexicalTokens(_ q:String)->[String]{
  let all=q.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count>=2 }
  let content=all.filter { !lexicalStopwords.contains($0) }
  var seen=Set<String>()
  var unique:[String]=[]
  for t in (content.isEmpty ? all : content) where seen.insert(t).inserted { unique.append(t) }
  return unique
 }
 /// Common English function words excluded from lexical scoring: they match
 /// nearly every chunk and carry no ranking signal.
 static let lexicalStopwords:Set<String>=[
  "the","a","an","and","or","but","if","then","else","of","to","in","on","for","with","without",
  "at","by","from","as","is","are","was","were","be","been","being","do","does","did","done",
  "this","that","these","those","it","its","they","them","their","we","you","your","me","my",
  "he","she","his","her","not","no","yes","can","could","should","would","will","shall","may",
  "might","must","have","has","had","about","into","over","after","before","between","under",
  "above","up","down","out","off","than","there","here","what","which","who","whom","when",
  "where","why","how","all","any","some","such","only","own","same","too","very","just"
 ]
 /// The semantic side of hybrid retrieval: ranks chunks whose embeddings are
 /// already cached by cosine similarity to the query vector, keeping the top
 /// candidates above a low floor (fusion, not this threshold, decides what
 /// surfaces). Returns empty — degrading retrieve to pure lexical — when the
 /// embedder can't produce a query vector, the cache is cold, or the embed
 /// exceeds ``hybridSemanticEmbedTimeoutNanoseconds`` (a cold embedding-model
 /// load must never stall a question).
 func semanticPassages(_ q:String,scope:Set<UUID>?=nil)async->[Passage]{
  let term=q.trimmingCharacters(in:.whitespacesAndNewlines)
  guard !term.isEmpty,!index.isEmpty,!embeddings.isEmpty else { return [] }
  guard let queryVector=await cachedQueryVector(for:term),!queryVector.isEmpty else { return [] }
  var scored:[(IndexedChunk,Double)]=[]
  for c in index {
   if let scope,!scope.contains(c.documentID) { continue }
   guard let vector=embeddings[c.id],vector.count==queryVector.count else { continue }
   let similarity=Double(Self.fastDot(queryVector,vector))
   if similarity >= Self.hybridSemanticFloor { scored.append((c,similarity)) }
  }
  // Build passages only for the kept candidates, in memory (no concept reads).
  return scored.sorted { $0.1 > $1.1 }
   .prefix(Self.hybridSemanticCandidateLimit)
   .map { makePassageInMemory(for:$0.0,score:$0.1) }
 }
 /// The query vector for `term`, from the LRU cache when present and otherwise
 /// from the embedder under a timeout. `nil` means "semantic unavailable for
 /// this question", never an error.
 func cachedQueryVector(for term:String)async->[Float]?{
  if let i=queryVectorCache.firstIndex(where: { $0.key==term }) {
   let entry=queryVectorCache.remove(at:i)
   queryVectorCache.append(entry)
   return entry.vector
  }
  guard let vector=await Self.embedWithTimeout({ try await self.embedder.embed(term) }),!vector.isEmpty else { return nil }
  queryVectorCache.append((term,vector))
  if queryVectorCache.count>Self.queryVectorCacheLimit {
   queryVectorCache.removeFirst(queryVectorCache.count-Self.queryVectorCacheLimit)
  }
  return vector
 }
 /// Races `operation` against a sleep and yields `nil` when the sleep wins, so a
 /// cold or slow embedder degrades Ask to lexical-only instead of blocking it.
 static func embedWithTimeout(_ operation:@escaping @Sendable ()async throws->[Float])async->[Float]?{
  await withTaskGroup(of:[Float]?.self) { group in
   group.addTask { try? await operation() }
   group.addTask {
    try? await Task.sleep(nanoseconds:Self.hybridSemanticEmbedTimeoutNanoseconds)
    return nil
   }
   let first=await group.next() ?? nil
   group.cancelAll()
   return first
  }
 }
 /// Dot product over the (normalized) embedding vectors. `vDSP_dotpr` keeps the
 /// whole-library cosine scan off the scalar interpreter for 1024-dim vectors.
 static func fastDot(_ a:[Float],_ b:[Float])->Float{
  let count=min(a.count,b.count)
  guard count>0 else { return 0 }
  #if canImport(Accelerate)
  var result:Float=0
  a.withUnsafeBufferPointer { x in
   b.withUnsafeBufferPointer { y in
    guard let xb=x.baseAddress,let yb=y.baseAddress else { return }
    vDSP_dotpr(xb,1,yb,1,&result,vDSP_Length(count))
   }
  }
  return result
  #else
  return dot(a,b)
  #endif
 }
 /// Reciprocal Rank Fusion constant; the standard k=60 flattens the influence
 /// of top ranks so a hit strong in only one list can't dominate unfairly.
 static let rrfK=60
 /// Cosine floor for hybrid semantic candidates (deliberately lower than Deep
 /// Search's 0.5 display threshold: RRF re-ranks, it doesn't show raw scores).
 static let hybridSemanticFloor=0.30
 /// Maximum semantic candidates entering fusion.
 static let hybridSemanticCandidateLimit=32
 /// Fraction of the query's total IDF weight a chunk must match to stay a
 /// lexical candidate. This is the flood control for long questions: matching a
 /// single common word used to be enough to enter the candidate list.
 static let hybridLexicalCoverageFloor=0.20
 /// Top-scoring lexical candidates always retained, whatever the floor says, so
 /// retrieval never comes back empty on a small library or a terse question.
 static let lexicalMinRetained=6
 /// Score bonus for a chunk containing the whole query phrase.
 static let lexicalPhraseBonus=0.75
 /// Maximum lexical candidates entering fusion (the pass was unbounded before).
 static let hybridLexicalCandidateLimit=64
 /// How long Ask waits for the query embedding before answering lexically only.
 static let hybridSemanticEmbedTimeoutNanoseconds:UInt64=3_000_000_000
 /// Query vectors cached for repeat and follow-up questions.
 static let queryVectorCacheLimit=16
 /// Drops the weak tail of a fused list: anything below
 /// ``hybridFusedScoreFloorRatio`` × the top fused score. With RRF k=60 a hit
 /// present in only one list at rank 0 scores half the top both-list hit, so
 /// this keeps the useful single-list head and cuts the marginal entries that
 /// make the model hedge. The list from `fuseRRF` is already score-descending.
 static func pruneWeakFused(_ passages:[Passage])->[Passage]{
  guard let top=passages.first?.score,top>0 else { return passages }
  let floor=top*hybridFusedScoreFloorRatio
  return passages.filter { $0.score >= floor }
 }
 /// Fused-score retention ratio (see ``pruneWeakFused(_:)``).
 static let hybridFusedScoreFloorRatio=0.4
 /// Fuses two ranked passage lists by RRF: score = Σ 1/(k + rank). Passages are
 /// matched across lists by conceptID (fallback documentID+offset). Ties break
 /// on the fusion key so ordering is deterministic. The winning passage keeps
 /// its original text/citation; `score` carries the fused value.
 static func fuseRRF(lexical:[Passage],semantic:[Passage])->[Passage]{
  func key(_ p:Passage)->String {
   p.citation.conceptID ?? "\(p.citation.documentID?.uuidString ?? p.citation.document)-\(p.citation.location ?? 0)"
  }
  var best:[String:Passage]=[:]
  var scores:[String:Double]=[:]
  for (rank,p) in lexical.enumerated() {
   let k=key(p)
   scores[k,default:0] += 1.0/Double(rrfK+rank+1)
   if best[k]==nil { best[k]=p }
  }
  for (rank,p) in semantic.enumerated() {
   let k=key(p)
   scores[k,default:0] += 1.0/Double(rrfK+rank+1)
   if best[k]==nil { best[k]=p }
  }
  return scores.keys
   .sorted { (scores[$0] ?? 0) != (scores[$1] ?? 0) ? (scores[$0] ?? 0) > (scores[$1] ?? 0) : $0 < $1 }
   .compactMap { k in best[k].map { Passage(text:$0.text,citation:$0.citation,score:scores[k] ?? 0) } }
 }
 public func retrievedExcerptText(_ q:String)async->String{(await retrieve(q)).enumerated().map{"[Excerpt \($0+1)]\nOKF concept: \($1.citation.conceptID ?? "unknown")\nSource: \($1.citation.document)\($1.citation.page.map{", page \($0)"} ?? "") offset \($1.citation.location ?? 0)\n\($1.text)"}.joined(separator:"\n\n")}

}
