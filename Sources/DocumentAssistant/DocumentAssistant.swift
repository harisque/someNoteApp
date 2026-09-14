import Foundation
#if canImport(PDFKit)
import PDFKit
#endif
public enum PromptMode:String,CaseIterable,Codable{case ask}
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
public protocol DocumentEmbedder:Sendable{func embed(_ text:String)async throws->[Float]}
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
 public internal(set)var documents:[Document]=[];public internal(set)var folders:[Folder]=[];public let model:LanguageModel;public let store:URL;private var index:[IndexedChunk]=[]
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
 /// Deterministic ids for the two permanent "AI Notes" system folders, so note
 /// `folderID` references stay valid across launches even before persistence.
 nonisolated static let personalAINotesFolderID=UUID(uuidString:"00000000-0000-0000-0000-0000000000a1")!
 nonisolated static let confidentialAINotesFolderID=UUID(uuidString:"00000000-0000-0000-0000-0000000000c1")!
 nonisolated static func aiNotesFolderID(for c:DocumentCategory)->UUID{c == .confidential ? confidentialAINotesFolderID : personalAINotesFolderID}
 /// Total input-token ceiling for a composed prompt (mirrors the app's configured context window).
 let promptTokenBudget:Int
 /// Tokens reserved for the model's answer so input + output stay within the ceiling.
 let reservedAnswerTokens:Int
 public init(model:LanguageModel,store:URL,embedder:DocumentEmbedder=HashEmbedder(),legacyStore:URL?=nil,promptTokenBudget:Int=4096,reservedAnswerTokens:Int=512) {
  self.model=model
  self.store=store
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
 }
 func persist()throws{
  index=documents.flatMap { Self.makeChunks(document:$0) }
  try FileManager.default.createDirectory(at:store.deletingLastPathComponent(),withIntermediateDirectories:true)
  try bundle().write(documents:documents,sections:index,dataLinks:dataLinks,summaries:dataLinkSummaries())
  try JSONEncoder().encode(documents).write(to:store,options:.atomic)
  try JSONEncoder().encode(index).write(to:store.deletingPathExtension().appendingPathExtension("index.json"),options:.atomic)
  try JSONEncoder().encode(folders).write(to:foldersURL,options:.atomic)
  try JSONEncoder().encode(dataLinks).write(to:dataLinksURL,options:.atomic)
 }
 public func deleteDocument(id:UUID)throws{if let d=documents.first(where:{$0.id==id}),d.category == .confidential,!d.isNote{throw DocumentError.confidentialReadOnly};let removed=documents.filter{$0.id==id};documents.removeAll{$0.id==id};index.removeAll{$0.documentID==id};removeSourceFiles(removed);try persist()}
 public func deleteDocuments(at o:IndexSet)throws{let targeted=documents.enumerated().filter{o.contains($0.offset)}.map{$0.element};if targeted.contains(where:{$0.category == .confidential && !$0.isNote}){throw DocumentError.confidentialReadOnly};let ids=targeted.map{$0.id};documents=documents.enumerated().filter{!o.contains($0.offset)}.map{$0.element};index.removeAll{ids.contains($0.documentID)};removeSourceFiles(targeted);try persist()}
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

 private static func makeChunks(document d:Document)->[IndexedChunk] {
  let source = d.text as NSString
  let full = NSRange(location:0,length:source.length)
  let regex = try? NSRegularExpression(pattern:#"(?m)^\[Page ([0-9]+)\][ \t]*\r?\n?"#)
  let markers = regex?.matches(in:d.text,range:full) ?? []
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
     chunks.append(IndexedChunk(documentID:d.id,document:d.name,text:text,page:page,location:range.location))
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
 public func retrieve(_ q:String,limit:Int=6)async->[Passage]{
  if index.isEmpty { for d in documents { try? await rebuildIndex(for:d) } }
  let bundle=self.bundle()
  if !FileManager.default.fileExists(atPath:bundle.root.path) { try? bundle.write(documents:documents,sections:index,dataLinks:dataLinks,summaries:dataLinkSummaries()) }
  let ts=q.lowercased().split { !$0.isLetter && !$0.isNumber }
  var results:[Passage]=[]
  for c in index {
   let conceptID=bundle.conceptID(for:c)
   let concept=try? bundle.readConcept(id:conceptID)
   let text=concept?.body.trimmingCharacters(in:.whitespacesAndNewlines) ?? c.text
   let low=text.lowercased()
   var n=0
   for t in ts { if low.contains(t) { n += 1 } }
   if !q.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && low.contains(q.lowercased()) { n += 3 }
   if n>0 { results.append(Passage(text:text,citation:Citation(document:c.document,page:c.page,location:c.location,length:text.utf16.count,conceptID:conceptID,documentID:c.documentID),score:Double(n))) }
  }
  // Score Data Link concepts so Ask can surface and cite live structured data
  // alongside document sections. Each link contributes one compact summary passage
  // whose citation navigates to the Data Link (conceptID prefix `datalinks/`).
  let summaries=dataLinkSummaries()
  let trimmedQuery=q.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
  for link in dataLinks {
   let summaryText=summaries[link.id] ?? link.scopeDescription
   guard !summaryText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { continue }
   let conceptID="datalinks/\(link.id.uuidString.lowercased())"
   let haystack=(summaryText+" "+link.name+" "+link.symbol).lowercased()
   var n=0
   for t in ts { if haystack.contains(t) { n += 1 } }
   if !trimmedQuery.isEmpty && haystack.contains(trimmedQuery) { n += 3 }
   if n>0 { results.append(Passage(text:summaryText,citation:Citation(document:link.name,page:nil,location:nil,length:summaryText.utf16.count,conceptID:conceptID,documentID:nil),score:Double(n))) }
  }
  return results.sorted { $0.score > $1.score }.prefix(max(0,limit)).map { $0 }
 }
 public func retrievedExcerptText(_ q:String)async->String{(await retrieve(q)).enumerated().map{"[Excerpt \($0+1)]\nOKF concept: \($1.citation.conceptID ?? "unknown")\nSource: \($1.citation.document)\($1.citation.page.map{", page \($0)"} ?? "") offset \($1.citation.location ?? 0)\n\($1.text)"}.joined(separator:"\n\n")}

}
