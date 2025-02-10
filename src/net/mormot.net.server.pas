/// HTTP/HTTPS Server Classes
// - this unit is a part of the Open Source Synopse mORMot framework 2,
// licensed under a MPL/GPL/LGPL three license - see LICENSE.md
unit mormot.net.server;

{
  *****************************************************************************

   HTTP/UDP Server Classes
   - Abstract UDP Server
   - Custom URI Routing using an efficient Radix Tree
   - Shared Server-Side HTTP Process
   - THttpServerSocket/THttpServer HTTP/1.1 Server
   - THttpPeerCache Local Peer-to-peer Cache
   - THttpApiServer HTTP/1.1 Server Over Windows http.sys Module
   - THttpApiWebSocketServer Over Windows http.sys Module

  *****************************************************************************

}

interface

{$I ..\mormot.defines.inc}

uses
  sysutils,
  classes,
  mormot.core.base,
  mormot.core.os,
  mormot.core.os.security,
  mormot.core.data,
  mormot.core.threads,
  mormot.core.unicode,
  mormot.core.text,
  mormot.core.buffers,
  mormot.core.rtti,
  mormot.core.json,
  mormot.core.datetime,
  mormot.core.zip,
  mormot.core.log,
  mormot.core.search,
  mormot.net.sock,
  mormot.net.http,
  {$ifdef USEWININET}
  mormot.lib.winhttp,
  {$endif USEWININET}
  mormot.lib.sspi,   // void unit on POSIX
  mormot.lib.gssapi, // void unit on Windows
  mormot.net.client,
  mormot.crypt.core,
  mormot.crypt.secure;


{ ******************** Abstract UDP Server }

type
  EUdpServer = class(ENetSock);

  /// work memory buffer of the maximum size of UDP frame (64KB)
  TUdpFrame = array[word] of byte;

  /// pointer to a memory buffer of the maximum size of UDP frame
  PUdpFrame = ^TUdpFrame;

  /// abstract UDP server thread
  TUdpServerThread = class(TLoggedThread)
  protected
    fSock: TNetSocket;
    fSockAddr: TNetAddr;
    fExecuteMessage: RawUtf8;
    fFrame: PUdpFrame;
    fReceived: integer;
    function GetIPWithPort: RawUtf8;
    procedure AfterBind; virtual;
    /// will loop for any pending UDP frame, and execute FrameReceived method
    procedure DoExecute; override;
    // this is the main processing method for all incoming frames
    procedure OnFrameReceived(len: integer; var remote: TNetAddr); virtual; abstract;
    procedure OnIdle(tix64: Int64); virtual; // called every 512 ms at most
    procedure OnShutdown; virtual; abstract;
  public
    /// initialize and bind the server instance, in non-suspended state
    constructor Create(LogClass: TSynLogClass;
      const BindAddress, BindPort, ProcessName: RawUtf8;
      TimeoutMS: integer); reintroduce;
    /// finalize the processing thread
    destructor Destroy; override;
  published
    property IPWithPort: RawUtf8
      read GetIPWithPort;
    property Received: integer
      read fReceived;
  end;

const
  /// the UDP frame content as sent by TUdpServerThread.Destroy
  UDP_SHUTDOWN: RawUtf8 = 'shutdown';


{ ******************** Custom URI Routing using an efficient Radix Tree }

type
  /// one HTTP method supported by TUriRouter
  // - only supports RESTful GET/POST/PUT/DELETE/OPTIONS/HEAD by default
  // - each method would have its dedicated TUriTree parser in TUriRouter
  TUriRouterMethod = (
    urmGet,
    urmPost,
    urmPut,
    urmDelete,
    urmOptions,
    urmHead,
    urmPatch);

  /// the HTTP methods supported by TUriRouter
  TUriRouterMethods = set of TUriRouterMethod;

  /// context information, as cloned by TUriTreeNode.Split()
  TUriTreeNodeData = record
    /// the Rewrite() URI text
    ToUri: RawUtf8;
    /// [pos1,len1,valndx1,pos2,len2,valndx2,...] trios from ToUri content
    ToUriPosLen: TIntegerDynArray;
    /// the size of all ToUriPosLen[] static content
    ToUriStaticLen: integer;
    /// the URI method to be used after ToUri rewrite
    ToUriMethod: TUriRouterMethod;
    /// the HTTP error code for a Rewrite() with an integer ToUri (e.g. '404')
    ToUriErrorStatus: {$ifdef CPU32} word {$else} cardinal {$endif};
    /// the callback registered by Run() for this URI
    Execute: TOnHttpServerRequest;
    /// an additional pointer value, assigned to Ctxt.RouteOpaque of Execute()
    ExecuteOpaque: pointer;
  end;

  /// implement a Radix Tree node to hold one URI registration
  TUriTreeNode = class(TRadixTreeNodeParams)
  protected
    function LookupParam(Ctxt: TObject; Pos: PUtf8Char; Len: integer): boolean;
      override;
    procedure RewriteUri(Ctxt: THttpServerRequestAbstract);
  public
    /// all context information, as cloned by Split()
    Data: TUriTreeNodeData;
    /// overriden to support the additional Data fields
    function Split(const Text: RawUtf8): TRadixTreeNode; override;
  end;

  /// implement a Radix Tree to hold all registered URI for a given HTTP method
  TUriTree = class(TRadixTreeParams)
  public
    /// access to the root node of this tree
    function Root: TUriTreeNode;
      {$ifdef HASINLINE}inline;{$endif}
  end;

  /// exception class raised during TUriRouter.Rewrite/Run registration
  EUriRouter = class(ERadixTree);

  /// store per-method URI multiplexing Radix Tree in TUriRouter
  // - each HTTP method would have its dedicated TUriTree parser in TUriRouter
  TUriRouterTree = array[urmGet .. high(TUriRouterMethod)] of TUriTree;

  /// efficient server-side URI routing for THttpServerGeneric
  // - Process() is done with no memory allocation for a static route,
  // using a very efficient Radix Tree for path lookup, over a thread-safe
  // non-blocking URI parsing with values extractions for rewrite or execution
  // - here are some numbers from TNetworkProtocols._TUriTree on my laptop:
  // $ 1000 URI lookups in 37us i.e. 25.7M/s, aver. 37ns
  // $ 1000 URI static rewrites in 80us i.e. 11.9M/s, aver. 80ns
  // $ 1000 URI parametrized rewrites in 117us i.e. 8.1M/s, aver. 117ns
  // $ 1000 URI static execute in 91us i.e. 10.4M/s, aver. 91ns
  // $ 1000 URI parametrized execute in 162us i.e. 5.8M/s, aver. 162ns
  TUriRouter = class(TObjectRWLightLock)
  protected
    fTree: TUriRouterTree;
    fTreeOptions: TRadixTreeOptions;
    fEntries: array[urmGet .. high(TUriRouterMethod)] of integer;
    fTreeNodeClass: TRadixTreeNodeClass;
    procedure Setup(aFrom: TUriRouterMethod; const aFromUri: RawUtf8;
      aTo: TUriRouterMethod; const aToUri: RawUtf8;
      const aExecute: TOnHttpServerRequest; aExecuteOpaque: pointer);
  public
    /// initialize this URI routing engine
    constructor Create(aNodeClass: TRadixTreeNodeClass;
      aOptions: TRadixTreeOptions = []); reintroduce;
    /// finalize this URI routing engine
    destructor Destroy; override;

    /// register an URI rewrite with optional <param> place holders
    // - <param> will be replaced in aToUri
    // - if aToUri is an '200'..'599' integer, it will return it as HTTP error
    // - otherwise, the URI will be rewritten into aToUri, e.g.
    // $ Rewrite(urmGet, '/info', urmGet, 'root/timestamp/info');
    // $ Rewrite(urmGet, '/path/from/<from>/to/<to>', urmPost,
    // $  '/root/myservice/convert?from=<from>&to=<to>'); // for IMyService.Convert
    // $ Rewrite(urmGet, '/index.php', '400'); // to avoid fuzzing
    // $ Rewrite(urmGet, '/*', '/static/*' // '*' synonymous to '<path:path>'
    procedure Rewrite(aFrom: TUriRouterMethod; const aFromUri: RawUtf8;
      aTo: TUriRouterMethod; const aToUri: RawUtf8);
    /// just a wrapper around Rewrite(urmGet, aFrom, aToMethod, aTo)
    // - e.g. Route.Get('/info', 'root/timestamp/info');
    // - e.g. Route.Get('/user/<id>', '/root/userservice/new?id=<id>'); will
    // rewrite internally '/user/1234' URI as '/root/userservice/new?id=1234'
    // - e.g. Route.Get('/user/<int:id>', '/root/userservice/new?id=<id>');
    // to ensure id is a real integer before redirection
    // - e.g. Route.Get('/admin.php', '403');
    // - e.g. Route.Get('/*', '/static/*'); with '*' synonymous to '<path:path>'
    procedure Get(const aFrom, aTo: RawUtf8;
      aToMethod: TUriRouterMethod = urmGet); overload;
    /// just a wrapper around Rewrite(urmPost, aFrom, aToMethod, aTo)
    // - e.g. Route.Post('/doconvert', '/root/myservice/convert');
    procedure Post(const aFrom, aTo: RawUtf8;
      aToMethod: TUriRouterMethod = urmPost); overload;
    /// just a wrapper around Rewrite(urmPut, aFrom, aToMethod, aTo)
    // - e.g. Route.Put('/domodify', '/root/myservice/update', urmPost);
    procedure Put(const aFrom, aTo: RawUtf8;
      aToMethod: TUriRouterMethod = urmPut); overload;
    /// just a wrapper around Rewrite(urmPatch, aFrom, aToMethod, aTo)
    // - e.g. Route.Patch('/domodify', '/root/myservice/update', urmPatch);
    procedure Patch(const aFrom, aTo: RawUtf8;
      aToMethod: TUriRouterMethod = urmPatch); overload;
    /// just a wrapper around Rewrite(urmDelete, aFrom, aToMethod, aTo)
    // - e.g. Route.Delete('/doremove', '/root/myservice/delete', urmPost);
    procedure Delete(const aFrom, aTo: RawUtf8;
      aToMethod: TUriRouterMethod = urmDelete); overload;
    /// just a wrapper around Rewrite(urmOptions, aFrom, aToMethod, aTo)
    // - e.g. Route.Options('/doremove', '/root/myservice/Options', urmPost);
    procedure Options(const aFrom, aTo: RawUtf8;
      aToMethod: TUriRouterMethod = urmOptions); overload;
    /// just a wrapper around Rewrite(urmHead, aFrom, aToMethod, aTo)
    // - e.g. Route.Head('/doremove', '/root/myservice/Head', urmPost);
    procedure Head(const aFrom, aTo: RawUtf8;
      aToMethod: TUriRouterMethod = urmHead); overload;

    /// assign a TOnHttpServerRequest callback with a given URI
    // - <param> place holders will be parsed and available in callback
    // as Ctxt['param'] default property or Ctxt.RouteInt64/RouteEquals methods
    // - could be used e.g. for standard REST process as
    // $ Route.Run([urmGet], '/user/<user>/pic', DoUserPic) // retrieve a list
    // $ Route.Run([urmGet, urmPost, urmPut, urmDelete],
    // $    '/user/<user>/pic/<id>', DoUserPic) // CRUD picture access
    procedure Run(aFrom: TUriRouterMethods; const aFromUri: RawUtf8;
      const aExecute: TOnHttpServerRequest; aExecuteOpaque: pointer = nil);
    /// just a wrapper around Run([urmGet], aUri, aExecute) registration method
    // - e.g. Route.Get('/plaintext', DoPlainText);
    procedure Get(const aUri: RawUtf8; const aExecute: TOnHttpServerRequest;
      aExecuteOpaque: pointer = nil); overload;
    /// just a wrapper around Run([urmPost], aUri, aExecute) registration method
    procedure Post(const aUri: RawUtf8; const aExecute: TOnHttpServerRequest;
      aExecuteOpaque: pointer = nil); overload;
    /// just a wrapper around Run([urmPut], aUri, aExecute) registration method
    procedure Put(const aUri: RawUtf8; const aExecute: TOnHttpServerRequest;
      aExecuteOpaque: pointer = nil); overload;
    /// just a wrapper around Run([urmPatch], aUri, aExecute) registration method
    procedure Patch(const aUri: RawUtf8; const aExecute: TOnHttpServerRequest;
      aExecuteOpaque: pointer = nil); overload;
    /// just a wrapper around Run([urmDelete], aUri, aExecute) registration method
    procedure Delete(const aUri: RawUtf8; const aExecute: TOnHttpServerRequest;
      aExecuteOpaque: pointer = nil); overload;
    /// just a wrapper around Run([urmOptions], aUri, aExecute) registration method
    procedure Options(const aUri: RawUtf8; const aExecute: TOnHttpServerRequest;
      aExecuteOpaque: pointer = nil); overload;
    /// just a wrapper around Run([urmHead], aUri, aExecute) registration method
    procedure Head(const aUri: RawUtf8; const aExecute: TOnHttpServerRequest;
      aExecuteOpaque: pointer = nil); overload;
    /// assign the published methods of a class instance to their URI via RTTI
    // - the signature of each method should match TOnHttpServerRequest
    // - the method name is used for the URI, e.g. Instance.user as '/user',
    // with exact case matching, and replacing _ in the method name by '-', e.g.
    // Instance.cached_query as '/cached-query'
    procedure RunMethods(RouterMethods: TUriRouterMethods; Instance: TObject;
      const Prefix: RawUtf8 = '/');

    /// perform URI parsing and rewrite/execution within HTTP server Ctxt members
    // - should return 0 to continue the process, on a HTTP status code to abort
    // if the request has been handled by a TOnHttpServerRequest callback
    // - this method is thread-safe
    function Process(Ctxt: THttpServerRequestAbstract): integer;
    /// search for a given URI match
    // - could be used e.g. in OnBeforeBody() to quickly reject an invalid URI
    // - this method is thread-safe
    function Lookup(const aUri, aUriMethod: RawUtf8): TUriTreeNode;
    /// erase all previous registrations, optionally for a given HTTP method
    // - currently, there is no way to delete a route once registered, to
    // optimize the process thread-safety: use Clear then re-register
    procedure Clear(aMethods: TUriRouterMethods = [urmGet .. high(TUriRouterMethod)]);
    /// access to the internal per-method TUriTree instance
    // - some Tree[] may be nil if the HTTP method has not been registered yet
    // - used only for testing/validation purpose
    property Tree: TUriRouterTree
      read fTree;
    /// how the TUriRouter instance should be created
    // - should be set before calling Run/Rewrite registration methods
    property TreeOptions: TRadixTreeOptions
      read fTreeOptions write fTreeOptions;
  published
    /// how many GET rules have been registered
    property Gets: integer
      read fEntries[urmGet];
    /// how many POST rules have been registered
    property Posts: integer
      read fEntries[urmPost];
    /// how many PUT rules have been registered
    property Puts: integer
      read fEntries[urmPut];
    /// how many PATCH rules have been registered
    property Patchs: integer
      read fEntries[urmPatch];
    /// how many DELETE rules have been registered
    property Deletes: integer
      read fEntries[urmDelete];
    /// how many HEAD rules have been registered
    property Heads: integer
      read fEntries[urmHead];
    /// how many OPTIONS rules have been registered
    property Optionss: integer
      read fEntries[urmOptions];
  end;

const
  /// convert TUriRouterMethod into its standard HTTP text
  // - see UriMethod() function for the reverse conversion
  URIROUTERMETHOD: array[TUriRouterMethod] of RawUtf8 = (
    'GET',     // urmGet
    'POST',    // urmPost
    'PUT',     // urmPut
    'DELETE',  // urmDelete
    'OPTIONS', // urmOptions
    'HEAD',    // urmHead
    'PATCH');  // urmPatch

/// quickly recognize most HTTP text methods into a TUriRouterMethod enumeration
// - may replace cascaded IsGet() IsPut() IsPost() IsDelete() function calls
// - see URIROUTERMETHOD[] constant for the reverse conversion
function UriMethod(const Text: RawUtf8; out Method: TUriRouterMethod): boolean;

/// check if the supplied text contains only valid characters for a root URI
// - excluding the parameters, i.e. rejecting the ? and % characters
// - but allowing <param> place holders as recognized by TUriRouter
function IsValidUriRoute(p: PUtf8Char): boolean;



{ ******************** Shared Server-Side HTTP Process }

type
  /// exception raised during HTTP process
  EHttpServer = class(ESynException);

  {$M+} // to have existing RTTI for published properties
  THttpServerGeneric = class;
  {$M-}

  /// 32-bit sequence value used to identify one asynchronous connection
  // - will start from 1, and increase during the server live-time
  // - THttpServerConnectionID may be retrieved from nginx reverse proxy
  // - used e.g. for Server.AsyncResponse() delayed call with HTTP_ASYNCRESPONSE
  TConnectionAsyncHandle = type integer;

  /// a dynamic array of TConnectionAsyncHandle identifiers
  TConnectionAsyncHandleDynArray = array of TConnectionAsyncHandle;

  /// a generic input/output structure used for HTTP server requests
  // - URL/Method/InHeaders/InContent properties are input parameters
  // - OutContent/OutContentType/OutCustomHeader are output parameters
  THttpServerRequest = class(THttpServerRequestAbstract)
  protected
    fServer: THttpServerGeneric;
    fConnectionAsyncHandle: TConnectionAsyncHandle;
    fErrorMessage: string;
    fTempWriter: TJsonWriter; // reused between SetOutJson() calls
    {$ifdef USEWININET}
    fHttpApiRequest: PHTTP_REQUEST;
    function GetFullUrl: SynUnicode;
    {$endif USEWININET}
  public
    /// initialize the context, associated to a HTTP server instance
    constructor Create(aServer: THttpServerGeneric;
      aConnectionID: THttpServerConnectionID; aConnectionThread: TSynThread;
      aConnectionAsyncHandle: TConnectionAsyncHandle;
      aConnectionFlags: THttpServerRequestFlags;
      aConnectionOpaque: PHttpServerConnectionOpaque); virtual;
    /// could be called before Prepare() to reuse an existing instance
    procedure Recycle(
      aConnectionID: THttpServerConnectionID; aConnectionThread: TSynThread;
      aConnectionAsyncHandle: TConnectionAsyncHandle;
      aConnectionFlags: THttpServerRequestFlags;
      aConnectionOpaque: PHttpServerConnectionOpaque);
    /// finalize this execution context
    destructor Destroy; override;
    /// prepare one reusable HTTP State Machine for sending the response
    function SetupResponse(var Context: THttpRequestContext;
      CompressGz, MaxSizeAtOnce: integer): PRawByteStringBuffer;
    /// just a wrapper around fErrorMessage := FormatString()
    procedure SetErrorMessage(const Fmt: RawUtf8; const Args: array of const);
    /// serialize a given value as JSON into OutContent and OutContentType fields
    // - this function returns HTTP_SUCCESS
    function SetOutJson(Value: pointer; TypeInfo: PRttiInfo): cardinal; overload;
      {$ifdef HASINLINE} inline; {$endif}
    /// serialize a given TObject as JSON into OutContent and OutContentType fields
    // - this function returns HTTP_SUCCESS
    function SetOutJson(Value: TObject): cardinal; overload;
      {$ifdef HASINLINE} inline; {$endif}
    /// low-level initialization of the associated TJsonWriter instance
    // - will reset and reuse an TJsonWriter associated to this execution context
    // - as called by SetOutJson() overloaded methods using RTTI
    // - a local TTextWriterStackBuffer should be provided as temporary buffer
    function TempJsonWriter(var temp: TTextWriterStackBuffer): TJsonWriter;
      {$ifdef HASINLINE} inline; {$endif}
    /// an additional custom parameter, as provided to TUriRouter.Setup
    function RouteOpaque: pointer; override;
    /// return the low-level internal handle for Server.AsyncResponse() delayed call
    // - to be used in conjunction with a HTTP_ASYNCRESPONSE internal status code
    // - raise an EHttpServer exception if async responses are not available
    function AsyncHandle: TConnectionAsyncHandle;
    /// the associated server instance
    // - may be a THttpServer or a THttpApiServer class
    property Server: THttpServerGeneric
      read fServer;
    /// optional error message which will be used by SetupResponse
    property ErrorMessage: string
      read fErrorMessage write fErrorMessage;
    {$ifdef USEWININET}
    /// for THttpApiServer, input parameter containing the caller full URL
    property FullUrl: SynUnicode
      read GetFullUrl;
    /// for THttpApiServer, points to a PHTTP_REQUEST structure
    property HttpApiRequest: PHTTP_REQUEST
      read fHttpApiRequest;
    {$endif USEWININET}
  end;
  /// meta-class of HTTP server requests instances
  THttpServerRequestClass = class of THttpServerRequest;

  /// available HTTP server options
  // - some THttpServerGeneric classes may have only partial support of them
  // - hsoHeadersUnfiltered will store all headers, not only relevant (i.e.
  // include raw Content-Length, Content-Type and Content-Encoding entries)
  // - hsoHeadersInterning triggers TRawUtf8Interning to reduce memory usage
  // - hsoNoStats will disable low-level statistic counters
  // - hsoNoXPoweredHeader excludes 'X-Powered-By: mORMot 2 synopse.info' header
  // - hsoCreateSuspended won't start the server thread immediately
  // - hsoLogVerbose could be used to debug a server in production
  // - hsoIncludeDateHeader will let all answers include a Date: ... HTTP header
  // - hsoEnableTls enables TLS support for THttpServer socket server, using
  // Windows SChannel API or OpenSSL - call WaitStarted() to set the certificates
  // - hsoBan40xIP will reject any IP for a few seconds after a 4xx error code
  // is returned (but 401/403) - only implemented by socket servers for now
  // - either hsoThreadCpuAffinity or hsoThreadSocketAffinity could be set: to
  // force thread affinity to one CPU logic core, or CPU HW socket; see
  // TNotifiedThread corresponding methods - not available on http.sys
  // - hsoReusePort will set SO_REUSEPORT on POSIX, allowing to bind several
  // THttpServerGeneric on the same port, either within the same process, or as
  // separated processes (e.g. to set process affinity to one CPU HW socket)
  // - hsoThreadSmooting will change the TAsyncConnections.ThreadPollingWakeup()
  // algorithm to focus the process on the first threads of the pool - by design,
  // this will disable both hsoThreadCpuAffinity and hsoThreadSocketAffinity
  // - hsoEnablePipelining enable HTTP pipelining (unsafe) on THttpAsyncServer
  // - hsoEnableLogging enable an associated THttpServerGeneric.Logger instance
  // - hsoTelemetryCsv and hsoTelemetryJson will enable CSV or JSON consolidated
  // per-minute metrics logging via an associated THttpServerGeneric.Analyzer
  THttpServerOption = (
    hsoHeadersUnfiltered,
    hsoHeadersInterning,
    hsoNoXPoweredHeader,
    hsoNoStats,
    hsoCreateSuspended,
    hsoLogVerbose,
    hsoIncludeDateHeader,
    hsoEnableTls,
    hsoBan40xIP,
    hsoThreadCpuAffinity,
    hsoThreadSocketAffinity,
    hsoReusePort,
    hsoThreadSmooting,
    hsoEnablePipelining,
    hsoEnableLogging,
    hsoTelemetryCsv,
    hsoTelemetryJson);

  /// how a THttpServerGeneric class is expected to process incoming requests
  THttpServerOptions = set of THttpServerOption;

  /// abstract parent class to implement a HTTP server
  // - do not use it, but rather THttpServer/THttpAsyncServer or THttpApiServer
  THttpServerGeneric = class(TNotifiedThread)
  protected
    fShutdownInProgress, fFavIconRouted: boolean;
    fOptions: THttpServerOptions;
    fDefaultRequestOptions: THttpRequestOptions;
    fRoute: TUriRouter;
    /// optional event handlers for process interception
    fOnRequest: TOnHttpServerRequest;
    fOnBeforeBody: TOnHttpServerBeforeBody;
    fOnBeforeRequest: TOnHttpServerRequest;
    fOnAfterRequest: TOnHttpServerRequest;
    fOnAfterResponse: TOnHttpServerAfterResponse;
    fMaximumAllowedContentLength: Int64;
    fCurrentConnectionID: integer;  // 31-bit NextConnectionID sequence
    /// set by RegisterCompress method
    fCompress: THttpSocketCompressRecDynArray;
    fCompressAcceptEncoding: RawUtf8;
    fServerName: RawUtf8;
    fRequestHeaders: RawUtf8; // pre-computed headers with ServerName
    fCallbackSendDelay: PCardinal;
    fCallbackOutgoingCount: PCardinal; //TODO
    fRemoteIPHeader, fRemoteIPHeaderUpper: RawUtf8;
    fRemoteConnIDHeader, fRemoteConnIDHeaderUpper: RawUtf8;
    fOnSendFile: TOnHttpServerSendFile;
    fFavIcon: RawByteString;
    fRouterClass: TRadixTreeNodeClass;
    fLogger: THttpLogger;
    fAnalyzer: THttpAnalyzer;
    function GetApiVersion: RawUtf8; virtual; abstract;
    procedure SetRouterClass(aRouter: TRadixTreeNodeClass);
    procedure SetServerName(const aName: RawUtf8); virtual;
    procedure SetOptions(opt: THttpServerOptions);
    procedure SetOnRequest(const aRequest: TOnHttpServerRequest); virtual;
    procedure SetOnBeforeBody(const aEvent: TOnHttpServerBeforeBody); virtual;
    procedure SetOnBeforeRequest(const aEvent: TOnHttpServerRequest); virtual;
    procedure SetOnAfterRequest(const aEvent: TOnHttpServerRequest); virtual;
    procedure SetOnAfterResponse(const aEvent: TOnHttpServerAfterResponse); virtual;
    procedure SetMaximumAllowedContentLength(aMax: Int64); virtual;
    procedure SetRemoteIPHeader(const aHeader: RawUtf8); virtual;
    procedure SetRemoteConnIDHeader(const aHeader: RawUtf8); virtual;
    function GetHttpQueueLength: cardinal; virtual; abstract;
    procedure SetHttpQueueLength(aValue: cardinal); virtual; abstract;
    function GetConnectionsActive: cardinal; virtual; abstract;
    function DoBeforeRequest(Ctxt: THttpServerRequest): cardinal;
      {$ifdef HASINLINE}inline;{$endif}
    function DoAfterRequest(Ctxt: THttpServerRequest): cardinal;
      {$ifdef HASINLINE}inline;{$endif}
    function NextConnectionID: integer; // 31-bit internal sequence
    procedure ParseRemoteIPConnID(const Headers: RawUtf8;
      var RemoteIP: RawUtf8; var RemoteConnID: THttpServerConnectionID);
      {$ifdef HASINLINE}inline;{$endif}
    procedure AppendHttpDate(var Dest: TRawByteStringBuffer); virtual;
    function GetFavIcon(Ctxt: THttpServerRequestAbstract): cardinal;
  public
    /// initialize the server instance
    constructor Create(const OnStart, OnStop: TOnNotifyThread;
      const ProcessName: RawUtf8; ProcessOptions: THttpServerOptions); reintroduce; virtual;
    /// release all memory and handlers used by this server
    destructor Destroy; override;
    /// specify URI routes for internal URI rewrites or callback execution
    // - rules registered here will be processed before main Request/OnRequest
    // - URI rewrites allow to extend the default routing, e.g. from TRestServer
    // - callbacks execution allow efficient server-side processing with parameters
    // - static routes could be defined e.g. Route.Get('/', '/root/default')
    // - <param> place holders could be defined for proper URI rewrite
    // e.g. Route.Post('/user/<id>', '/root/userservice/new?id=<id>') will
    // rewrite internally '/user/1234' URI as '/root/userservice/new?id=1234'
    // - could be used e.g. for standard REST process via event callbacks with
    // Ctxt['user'] or Ctxt.RouteInt64('id') parameter extraction in DoUserPic:
    // $ Route.Run([urmGet], '/user/<user>/pic', DoUserPic) // retrieve a list
    // $ Route.Run([urmGet, urmPost, urmPut, urmDelete],
    // $    '/user/<user>/pic/<id>', DoUserPic) // CRUD picture access
    // - warning: with the THttpApiServer, URIs will be limited by the actual
    // root URI registered at http.sys level - there is no such limitation with
    // the socket servers, which bind to a port, so handle all URIs on it
    function Route: TUriRouter;
    /// thread-safe replace the TUriRouter instance
    // - returns the existing instance: caller should keep it for a few seconds
    // untouched prior to Free it, to let finish any pending background process
    function ReplaceRoute(another: TUriRouter): TUriRouter;
    /// will route a GET to /favicon.ico to the given .ico file content
    // - if none is supplied, the default Synopse/mORMot icon is used
    // - if '' is supplied, /favicon.ico will return a 404 error status
    // - warning: with THttpApiServer, may require a proper URI registration
    procedure SetFavIcon(const FavIconContent: RawByteString = 'default');
    /// override this function to customize your http server
    // - InURL/InMethod/InContent properties are input parameters
    // - OutContent/OutContentType/OutCustomHeader are output parameters
    // - result of the function is the HTTP error code (200 if OK, e.g.),
    // - OutCustomHeader is available to handle Content-Type/Location
    // - if OutContentType is STATICFILE_CONTENT_TYPE (i.e. '!STATICFILE'),
    // then OutContent is the UTF-8 filename of a file to be sent directly
    // to the client via http.sys or NGINX's X-Accel-Redirect; the
    // OutCustomHeader should contain the eventual 'Content-type: ....' value
    // - default implementation is to call the OnRequest event (if existing),
    // and will return HTTP_NOTFOUND if OnRequest was not set
    // - warning: this process must be thread-safe (can be called by several
    // threads simultaneously, but with a given Ctxt instance for each)
    function Request(Ctxt: THttpServerRequestAbstract): cardinal; virtual;
    /// send a request back to the client, if the connection has been upgraded
    // e.g. to WebSockets
    // - InURL/InMethod/InContent properties are input parameters
    // (InContentType is ignored)
    // - OutContent/OutContentType/OutCustomHeader are output parameters
    // - Ctxt.ConnectionID should be set, so that the method could know
    // which connnection is to be used - returns HTTP_NOTFOUND (404) if unknown
    // - result of the function is the HTTP error code (200 if OK, e.g.)
    // - warning: this void implementation will raise an EHttpServer exception -
    // inherited classes should override it, e.g. as in TWebSocketServerRest
    function Callback(Ctxt: THttpServerRequest; aNonBlocking: boolean): cardinal; virtual;
    /// send an asynchronous response to the client, when a slow process (e.g.
    // DB request) has been executed
    // - warning: this void implementation will raise an EHttpServer exception -
    // inherited classes should override it, e.g. as in THttpAsyncServer
    procedure AsyncResponse(Connection: TConnectionAsyncHandle;
      const Content, ContentType: RawUtf8; Status: cardinal = HTTP_SUCCESS); virtual;
    /// send an asynchronous (JSON by default) response to the client
    procedure AsyncResponseFmt(Connection: TConnectionAsyncHandle;
      const ContentFmt: RawUtf8; const Args: array of const;
      const ContentType: RawUtf8 = JSON_CONTENT_TYPE;
      Status: cardinal = HTTP_SUCCESS);
    /// send an asynchronous RTTI-serialized JSON response to the client
    procedure AsyncResponseJson(Connection: TConnectionAsyncHandle;
      Value: pointer; TypeInfo: PRttiInfo; Status: cardinal = HTTP_SUCCESS);
    /// send an asynchronous text error response to the client
    procedure AsyncResponseError(Connection: TConnectionAsyncHandle;
      const Message: RawUtf8; Status: cardinal = HTTP_SERVERERROR);

    /// will register a compression algorithm
    // - used e.g. to compress on the fly the data, with standard gzip/deflate
    // or custom (synlz) protocols
    // - you can specify a minimal size (in bytes) before which the content won't
    // be compressed (1024 by default, corresponding to a MTU of 1500 bytes)
    // - the first registered algorithm will be the prefered one for compression
    // within each priority level (the lower aPriority first)
    procedure RegisterCompress(aFunction: THttpSocketCompress;
      aCompressMinSize: integer = 1024; aPriority: integer = 10); virtual;
    /// you can call this method to prepare the HTTP server for shutting down
    procedure Shutdown;
    /// allow to customize the Route() implementation Radix Tree node class
    // - if not set, will use TUriTreeNode as defined in this unit
    // - raise an Exception if set twice, or after Route() is called
    property RouterClass: TRadixTreeNodeClass
      read fRouterClass write SetRouterClass;
    /// main event handler called by the default implementation of the
    // virtual Request method to process a given request
    // - OutCustomHeader will handle Content-Type/Location
    // - if OutContentType is STATICFILE_CONTENT_TYPE (i.e. '!STATICFILE'),
    // then OutContent is the UTF-8 filename of a file to be sent directly
    // to the client via http.sys or NGINX's X-Accel-Redirect; the
    // OutCustomHeader should contain the eventual 'Content-type: ....' value
    // - warning: this process must be thread-safe (can be called by several
    // threads simultaneously)
    property OnRequest: TOnHttpServerRequest
      read fOnRequest write SetOnRequest;
    /// event handler called just before the body is retrieved from the client
    // - should return HTTP_SUCCESS=200 to continue the process, or an HTTP
    // error code to reject the request immediately, and close the connection
    property OnBeforeBody: TOnHttpServerBeforeBody
      read fOnBeforeBody write SetOnBeforeBody;
    /// event handler called after HTTP body has been retrieved, before OnRequest
    // - may be used e.g. to return a HTTP_ACCEPTED (202) status to client and
    // continue a long-term job inside the OnRequest handler in the same thread;
    // or to modify incoming information before passing it to main business logic,
    // (header preprocessor, body encoding etc...)
    // - if the handler returns > 0 server will send a response immediately,
    // unless return code is HTTP_ACCEPTED (202), then OnRequest will be called
    // - warning: this handler must be thread-safe (could be called from several
    // threads), and is NOT called before Route() callbacks execution
    property OnBeforeRequest: TOnHttpServerRequest
      read fOnBeforeRequest write SetOnBeforeRequest;
    /// event handler called after request is processed but before response
    // is sent back to client
    // - main purpose is to apply post-processor, not part of request logic
    // - if handler returns value > 0 it will override the OnRequest response code
    // - warning: this handler must be thread-safe (could be called from several
    // threads), and is NOT called after Route() callbacks execution
    property OnAfterRequest: TOnHttpServerRequest
      read fOnAfterRequest write SetOnAfterRequest;
    /// event handler called after response is sent back to client
    // - main purpose is to apply post-response analysis, logging, etc...
    // - warning: this handler must be thread-safe (could be called from several
    // threads), and IS called after Route() callbacks execution
    property OnAfterResponse: TOnHttpServerAfterResponse
      read fOnAfterResponse write SetOnAfterResponse;
    /// event handler called after each working Thread is just initiated
    // - called in the thread context at first place in THttpServerGeneric.Execute
    property OnHttpThreadStart: TOnNotifyThread
      read fOnThreadStart write fOnThreadStart;
    /// event handler called when a working Thread is terminating
    // - called in the corresponding thread context
    // - the TThread.OnTerminate event will be called within a Synchronize()
    // wrapper, so it won't fit our purpose
    // - to be used e.g. to call CoUnInitialize from thread in which CoInitialize
    // was made, for instance via a method defined as such:
    // ! procedure TMyServer.OnHttpThreadTerminate(Sender: TThread);
    // ! begin // TSqlDBConnectionPropertiesThreadSafe
    // !   fMyConnectionProps.EndCurrentThread;
    // ! end;
    // - is used e.g. by TRest.EndCurrentThread for proper multi-threading
    property OnHttpThreadTerminate: TOnNotifyThread
      read fOnThreadTerminate write SetOnTerminate;
    /// reject any incoming request with a body size bigger than this value
    // - default to 0, meaning any input size is allowed
    // - returns HTTP_PAYLOADTOOLARGE = 413 error if "Content-Length" incoming
    // header overflow the supplied number of bytes
    property MaximumAllowedContentLength: Int64
      read fMaximumAllowedContentLength write SetMaximumAllowedContentLength;
    /// custom event handler used to send a local file for STATICFILE_CONTENT_TYPE
    // - see also NginxSendFileFrom() method
    property OnSendFile: TOnHttpServerSendFile
      read fOnSendFile write fOnSendFile;
    /// defines request/response internal queue length
    // - default value if 1000, which sounds fine for most use cases
    // - for THttpApiServer, will return 0 if the system does not support HTTP
    // API 2.0 (i.e. under Windows XP or Server 2003)
    // - for THttpServer or THttpAsyncServer, will shutdown any incoming accepted
    // socket if the internal number of pending requests exceed this limit
    // - increase this value if you don't have any load-balancing in place, and
    // in case of e.g. many 503 HTTP answers or if many "QueueFull" messages
    // appear in HTTP.sys log files (normally in
    // C:\Windows\System32\LogFiles\HTTPERR\httperr*.log) - may appear with
    // thousands of concurrent clients accessing at once the same server -
    // see @http://msdn.microsoft.com/en-us/library/windows/desktop/aa364501
    // - you can use this property with a reverse-proxy as load balancer, e.g.
    // with nginx configured as such:
    // $ location / {
    // $       proxy_pass              http://balancing_upstream;
    // $       proxy_next_upstream     error timeout invalid_header http_500 http_503;
    // $       proxy_connect_timeout   2;
    // $       proxy_set_header        Host            $host;
    // $       proxy_set_header        X-Real-IP       $remote_addr;
    // $       proxy_set_header        X-Forwarded-For $proxy_add_x_forwarded_for;
    // $       proxy_set_header        X-Conn-ID       $connection
    // $ }
    // see https://synopse.info/forum/viewtopic.php?pid=28174#p28174
    property HttpQueueLength: cardinal
      read GetHttpQueueLength write SetHttpQueueLength;
    /// returns the number of current HTTP connections
    // - may not include HTTP/1.0 short-living connections
    property ConnectionsActive: cardinal
      read GetConnectionsActive;
    /// TRUE if the inherited class is able to handle callbacks
    // - only TWebSocketServer/TWebSocketAsyncServer have this ability by now
    function CanNotifyCallback: boolean;
      {$ifdef HASINLINE}inline;{$endif}
    /// the value of a custom HTTP header containing the real client IP
    // - by default, the RemoteIP information will be retrieved from the socket
    // layer - but if the server runs behind some proxy service, you should
    // define here the HTTP header name which indicates the true remote client
    // IP value, mostly as 'X-Real-IP' or 'X-Forwarded-For'
    property RemoteIPHeader: RawUtf8
      read fRemoteIPHeader write SetRemoteIPHeader;
    /// the value of a custom HTTP header containing the real client connection ID
    // - by default, Ctxt.ConnectionID information will be retrieved from our
    // socket layer - but if the server runs behind some proxy service, you should
    // define here the HTTP header name which indicates the real remote connection,
    // for example as 'X-Conn-ID', setting in nginx config:
    //  $ proxy_set_header      X-Conn-ID       $connection
    property RemoteConnIDHeader: RawUtf8
      read fRemoteConnIDHeader write SetRemoteConnIDHeader;
  published
    /// the Server name, UTF-8 encoded, e.g. 'mORMot2 (Linux)'
    // - will be served as "Server: ..." HTTP header
    // - for THttpApiServer, when called from the main instance, will propagate
    // the change to all cloned instances, and included in any HTTP API 2.0 log
    property ServerName: RawUtf8
      read fServerName write SetServerName;
    /// the associated process name
    property ProcessName: RawUtf8
      read fProcessName write fProcessName;
    /// returns the API version used by the inherited implementation
    property ApiVersion: RawUtf8
      read GetApiVersion;
    /// allow to customize this HTTP server instance
    // - some inherited classes may have only partial support of those options
    property Options: THttpServerOptions
      read fOptions write SetOptions;
    /// read access to the URI router, as published property (e.g. for logs)
    // - use the Route function to actually setup the routing
    // - may be nil if Route has never been accessed, i.e. no routing was set
    property Router: TUriRouter
      read fRoute;
    /// access to the HTTP logger initialized with hsoEnableLogging option
    // - you can customize the logging process via Logger.Format,
    // Logger.DestFolder, Logger.DefaultRotate, Logger.DefaultRotateFiles
    // properties and Logger.DefineHost() method
    // - equals nil if hsoEnableLogging was not set in the constructor
    property Logger: THttpLogger
      read fLogger;
    /// access to the HTTP analyzer initialized with hsoTelemetryCsv or
    // hsoTelemetryJson options
    // - you can customize this process via Analyzer.DestFolder
    property Analyzer: THttpAnalyzer
      read fAnalyzer;
  end;


const
  /// used to compute the request ConnectionFlags from the socket TLS state
  HTTP_TLS_FLAGS: array[{tls=}boolean] of THttpServerRequestFlags = (
    [],
    [hsrHttps, hsrSecured]);

  /// used to compute the request ConnectionFlags from connection: upgrade header
  HTTP_UPG_FLAGS: array[{tls=}boolean] of THttpServerRequestFlags = (
    [],
    [hsrConnectionUpgrade]);

  /// used to compute the request ConnectionFlags from HTTP/1.0 command
  HTTP_10_FLAGS: array[{http10=}boolean] of THttpServerRequestFlags = (
    [],
    [hsrHttp10]);

/// some pre-computed CryptCertOpenSsl[caaRS256].New key for Windows
// - the associated password is 'pass'
// - as used e.g. by THttpServerSocketGeneric.WaitStartedHttps
function PrivKeyCertPfx: RawByteString;

/// initialize a server-side TLS structure with a self-signed algorithm
// - as used e.g. by THttpServerSocketGeneric.WaitStartedHttps
// - if OpenSSL is available and UsePreComputed is false, will
// generate a temporary pair of key files via
// Generate(CU_TLS_SERVER, '127.0.0.1', nil, 3650) with a random password
// - if UsePreComputed=true or on pure SChannel, will use the PrivKeyCertPfx
// pre-computed constant
// - you should eventually call DeleteFile(Utf8ToString(TLS.CertificateFile))
// and DeleteFile(Utf8ToString(TLS.PrivateKeyFile)) to delete the two temp files
procedure InitNetTlsContextSelfSignedServer(var TLS: TNetTlsContext;
  Algo: TCryptAsymAlgo = caaRS256; UsePreComputed: boolean = false);

/// used by THttpServerGeneric.SetFavIcon to return a nice /favicon.ico
function FavIconBinary: RawByteString;

type
  /// define how GetMacAddress() makes its sorting choices
  // - used e.g. for THttpPeerCacheSettings.InterfaceFilter property
  // - mafEthernetOnly will only select TMacAddress.Kind = makEthernet
  // - mafLocalOnly will only select makEthernet or makWifi adapters
  // - mafRequireBroadcast won't return any TMacAddress with Broadcast = ''
  // - mafIgnoreGateway won't put the TMacAddress.Gateway <> '' first
  // - mafIgnoreKind and mafIgnoreSpeed will ignore Kind or Speed properties
  TMacAddressFilter = set of (
    mafEthernetOnly,
    mafLocalOnly,
    mafRequireBroadcast,
    mafIgnoreGateway,
    mafIgnoreKind,
    mafIgnoreSpeed);

/// pickup the most suitable network according to some preferences
// - will sort GetMacAddresses() results according to its Kind and Speed
// to select the most suitable local interface e.g. for THttpPeerCache
function GetMainMacAddress(out Mac: TMacAddress;
  Filter: TMacAddressFilter = []): boolean; overload;

/// get a network interface from its TMacAddress main fields
// - search is case insensitive for TMacAddress.Name and Address fields or as
// exact IP, and eventually as IP bitmask pattern (e.g. 192.168.1.255)
function GetMainMacAddress(out Mac: TMacAddress;
  const InterfaceNameAddressOrIP: RawUtf8;
  UpAndDown: boolean = false): boolean; overload;



{ ******************** THttpServerSocket/THttpServer HTTP/1.1 Server }

type
  /// results of THttpServerSocket.GetRequest virtual method
  // - grClosed is returned if the socket was disconnected/closed by the client
  // - grException is returned if any exception occurred during the process
  // - grOversizedPayload is returned when MaximumAllowedContentLength is reached
  // - grRejected on invalid input, or when OnBeforeBody returned not 200
  // - grIntercepted is returned e.g. from OnHeaderParsed as valid result
  // - grTimeout is returned when HeaderRetrieveAbortDelay is reached
  // - grHeaderReceived is returned for GetRequest({withbody=}false)
  // - grBodyReceived is returned for GetRequest({withbody=}true)
  // - grWwwAuthenticate is returned if GetRequest() did send a 401 response
  // - grUpgraded indicates that this connection was upgraded e.g. as WebSockets
  // - grBanned is triggered by the hsoBan40xIP option
  THttpServerSocketGetRequestResult = (
    grClosed,
    grException,
    grOversizedPayload,
    grRejected,
    grIntercepted,
    grTimeout,
    grHeaderReceived,
    grBodyReceived,
    grWwwAuthenticate,
    grUpgraded,
    grBanned);

  {$M+} // to have existing RTTI for published properties
  THttpServer = class;
  {$M-}

  /// Socket API based HTTP/1.1 server class used by THttpServer Threads
  THttpServerSocket = class(THttpSocket)
  protected
    fRemoteConnectionID: THttpServerConnectionID;
    fServer: THttpServer;
    fKeepAliveClient: boolean;
    fAuthorized: THttpServerRequestAuthentication;
    fRequestFlags: THttpServerRequestFlags;
    fAuthSec: cardinal;
    fConnectionOpaque: THttpServerConnectionOpaque; // two PtrUInt tags
    fResponseHeader: RawUtf8;
    // from TSynThreadPoolTHttpServer.Task
    procedure TaskProcess(aCaller: TSynThreadPoolWorkThread); virtual;
    function TaskProcessBody(aCaller: TSynThreadPoolWorkThread;
      aHeaderResult: THttpServerSocketGetRequestResult): boolean;
  public
    /// create the socket according to a server
    // - will register the THttpSocketCompress functions from the server
    // - once created, caller should call AcceptRequest() to accept the socket
    // - if TLS is enabled, ensure server certificates are initialized once
    constructor Create(aServer: THttpServer); reintroduce;
    /// main object function called after aClientSock := Accept + Create:
    // - get Command, Method, URL, Headers and Body (if withBody is TRUE)
    // - get sent data in Content (if withBody=true and ContentLength<>0)
    // - returned enumeration will indicates the processing state
    function GetRequest(withBody: boolean;
      headerMaxTix: Int64): THttpServerSocketGetRequestResult; virtual;
    /// access to the internal two PtrUInt tags of this connection
    // - may be nil behind a reverse proxy (i.e. Server.RemoteConnIDHeader<>'')
    function GetConnectionOpaque: PHttpServerConnectionOpaque;
      {$ifdef HASINLINE} inline; {$endif}
    /// contains the method ('GET','POST'.. e.g.) after GetRequest()
    property Method: RawUtf8
      read Http.CommandMethod;
    /// contains the URL ('/' e.g.) after GetRequest()
    property URL: RawUtf8
      read Http.CommandUri;
    /// true if the client is HTTP/1.1 and 'Connection: Close' is not set
    // - default HTTP/1.1 behavior is "keep alive", unless 'Connection: Close'
    // is specified, cf. RFC 2068 page 108: "HTTP/1.1 applications that do not
    // support persistent connections MUST include the "close" connection option
    // in every message"
    property KeepAliveClient: boolean
      read fKeepAliveClient write fKeepAliveClient;
    /// the recognized connection ID, after a call to GetRequest()
    // - identifies either the raw connection on the current server, or
    // the custom header value as set by a local proxy, e.g.
    // THttpServerGeneric.RemoteConnIDHeader='X-Conn-ID' for nginx
    property RemoteConnectionID: THttpServerConnectionID
      read fRemoteConnectionID;
    /// the associated HTTP Server instance - may be nil
    property Server: THttpServer
      read fServer;
  end;

  /// HTTP response Thread as used by THttpServer Socket API based class
  // - Execute procedure get the request and calculate the answer, using
  // the thread for a single client connection, until it is closed
  // - you don't have to overload the protected THttpServerResp Execute method:
  // override THttpServer.Request() function or, if you need a lower-level access
  // (change the protocol, e.g.) THttpServer.Process() method itself
  THttpServerResp = class(TSynThread)
  protected
    fConnectionID: THttpServerConnectionID;
    fServer: THttpServer;
    fServerSock: THttpServerSocket;
    fClientSock: TNetSocket;
    fClientSin: TNetAddr;
    /// main thread loop: read request from socket, send back answer
    procedure Execute; override;
  public
    /// initialize the response thread for the corresponding incoming socket
    // - this version will get the request directly from an incoming socket
    constructor Create(aSock: TNetSocket; const aSin: TNetAddr;
      aServer: THttpServer); reintroduce; overload;
    /// initialize the response thread for the corresponding incoming socket
    // - this version will handle KeepAlive, for such an incoming request
    constructor Create(aServerSock: THttpServerSocket; aServer: THttpServer);
      reintroduce; overload; virtual;
    /// called by THttpServer.Destroy on existing connections
    // - set Terminate and close the socket
    procedure Shutdown; virtual;
    /// the associated socket to communicate with the client
    property ServerSock: THttpServerSocket
      read fServerSock;
    /// the associated main HTTP server instance
    property Server: THttpServer
      read fServer;
    /// the unique identifier of this connection
    property ConnectionID: THttpServerConnectionID
      read fConnectionID;
  end;

  /// metaclass of HTTP response Thread
  THttpServerRespClass = class of THttpServerResp;

  /// a simple Thread Pool, used for fast handling HTTP requests of a THttpServer
  // - will handle multi-connection with less overhead than creating a thread
  // for each incoming request
  // - will create a THttpServerResp response thread, if the incoming request is
  // identified as HTTP/1.1 keep alive, or HTTP body length is bigger than 1 MB
  TSynThreadPoolTHttpServer = class(TSynThreadPool)
  protected
    fServer: THttpServer;
    fBigBodySize: integer;
    fMaxBodyThreadCount: integer;
    {$ifndef USE_WINIOCP}
    function QueueLength: integer; override;
    {$endif USE_WINIOCP}
    // here aContext is a THttpServerSocket instance
    procedure Task(aCaller: TSynThreadPoolWorkThread;
      aContext: pointer); override;
    procedure TaskAbort(aContext: pointer); override;
  public
    /// initialize a thread pool with the supplied number of threads
    // - Task() overridden method processs the HTTP request set by Push()
    // - up to 256 threads can be associated to a Thread Pool
    constructor Create(Server: THttpServer;
      NumberOfThreads: integer = 32); reintroduce;
    /// when Content-Length is bigger than this value, by-pass the threadpool
    // and creates a dedicated THttpServerResp thread
    // - default is THREADPOOL_BIGBODYSIZE = 16 MB, but can set a bigger value
    // e.g. behind a buffering proxy if you trust the client not to make DOD
    property BigBodySize: integer
      read fBigBodySize write fBigBodySize;
    /// how many stand-alone THttpServerResp threads can be initialized when a
    // HTTP request comes in
    // - default is THREADPOOL_MAXWORKTHREADS = 512, but since each thread
    // consume system memory, you should not go so high
    // - above this value, the thread pool will be used
    property MaxBodyThreadCount: integer
      read fMaxBodyThreadCount write fMaxBodyThreadCount;
  end;

  /// meta-class of the THttpServerSocket process
  // - used to override THttpServerSocket.GetRequest for instance
  THttpServerSocketClass = class of THttpServerSocket;

  /// callback used by THttpServerSocketGeneric.SetAuthorizeBasic
  // - should return true if supplied aUser/aPassword pair is valid
  TOnHttpServerBasicAuth = function(Sender: TObject;
    const aUser: RawUtf8; const aPassword: SpiUtf8): boolean of object;

  /// THttpServerSocketGeneric current state
  THttpServerExecuteState = (
    esNotStarted,
    esBinding,
    esRunning,
    esFinished);

  /// abstract parent class for both THttpServer and THttpAsyncServer
  THttpServerSocketGeneric = class(THttpServerGeneric)
  protected
    fSafe: TLightLock; // topmost to ensure proper aarch64 alignment
    fServerKeepAliveTimeOut: cardinal;
    fServerKeepAliveTimeOutSec: cardinal;
    fHeaderRetrieveAbortDelay: cardinal;
    fCompressGz: integer; // >=0 if GZ is activated
    fSockPort: RawUtf8;
    fSock: TCrtSocket;
    fExecuteMessage: RawUtf8;
    fNginxSendFileFrom: array of TFileName;
    fAuthorize: THttpServerRequestAuthentication;
    fAuthorizerBasic: IBasicAuthServer;
    fAuthorizerDigest: IDigestAuthServer;
    fAuthorizeBasic: TOnHttpServerBasicAuth;
    fAuthorizeBasicRealm: RawUtf8;
    fStats: array[THttpServerSocketGetRequestResult] of integer;
    fOnProgressiveRequestFree: THttpPartials;
    function HeaderRetrieveAbortTix: Int64;
    function DoRequest(Ctxt: THttpServerRequest): boolean; // fRoute or Request()
    procedure DoProgressiveRequestFree(var Ctxt: THttpRequestContext);
    procedure SetServerKeepAliveTimeOut(Value: cardinal);
    function GetStat(one: THttpServerSocketGetRequestResult): integer;
    procedure IncStat(one: THttpServerSocketGetRequestResult);
      {$ifdef HASINLINE} inline; {$endif}
    function OnNginxAllowSend(Context: THttpServerRequestAbstract;
      const LocalFileName: TFileName): boolean;
    // this overridden version will return e.g. 'Winsock 2.514'
    function GetApiVersion: RawUtf8; override;
    function GetExecuteState: THttpServerExecuteState; virtual; abstract;
    function GetRegisterCompressGzStatic: boolean;
    procedure SetRegisterCompressGzStatic(Value: boolean);
    function ComputeWwwAuthenticate(Opaque: Int64): RawUtf8;
    function SetRejectInCommandUri(var Http: THttpRequestContext;
      Opaque: Int64; Status: integer): boolean; // true for grWwwAuthenticate
    function Authorization(var Http: THttpRequestContext;
      Opaque: Int64): TAuthServerResult;
  public
    /// create a Server Thread, ready to be bound and listening on a port
    // - this constructor will raise a EHttpServer exception if binding failed
    // - expects the port to be specified as string, e.g. '1234'; you can
    // optionally specify a server address to bind to, e.g. '1.2.3.4:1234'
    // - can listed to local Unix Domain Sockets file in case port is prefixed
    // with 'unix:', e.g. 'unix:/run/myapp.sock' - faster and safer than TCP
    // - on Linux in case aPort is empty string will check if external fd
    // is passed by systemd and use it (so called systemd socked activation)
    // - you can specify a number of threads to be initialized to handle
    // incoming connections. Default is 32, which may be sufficient for most
    // cases, maximum is 256. If you set 0, the thread pool will be disabled
    // and one thread will be created for any incoming connection
    // - you can also tune (or disable with 0) HTTP/1.1 keep alive delay and
    // how incoming request Headers[] are pushed to the processing method
    // - this constructor won't actually do the port binding, which occurs in
    // the background thread: caller should therefore call WaitStarted after
    // THttpServer.Create()
    constructor Create(const aPort: RawUtf8;
      const OnStart, OnStop: TOnNotifyThread; const ProcessName: RawUtf8;
      ServerThreadPoolCount: integer = 32; KeepAliveTimeOut: integer = 30000;
      ProcessOptions: THttpServerOptions = []); reintroduce; virtual;
    /// defines the WebSockets protocols to be used for this Server
    // - this default implementation will raise an exception
    // - returns the associated PWebSocketProcessSettings reference on success
    function WebSocketsEnable(
      const aWebSocketsURI, aWebSocketsEncryptionKey: RawUtf8;
      aWebSocketsAjax: boolean = false;
      aWebSocketsBinaryOptions: TWebSocketProtocolBinaryOptions =
        [pboSynLzCompress]): pointer; virtual;
    /// ensure the HTTP server thread is actually bound to the specified port
    // - TCrtSocket.Bind() occurs in the background in the Execute method: you
    // should call and check this method result just after THttpServer.Create
    // - initial THttpServer design was to call Bind() within Create, which
    // works fine on Delphi + Windows, but fails with a EThreadError on FPC/Linux
    // - raise a EHttpServer if binding failed within the specified period (if
    // port is free, it would be almost immediate)
    // - calling this method is optional, but if the background thread didn't
    // actually bind the port, the server will be stopped and unresponsive with
    // no explicit error message, until it is terminated
    // - for hsoEnableTls support, you should either specify the private key
    // and certificate here, or set TLS.PrivateKeyFile/CertificateFile fields -
    // the benefit of this method parameters is that the certificates are
    // loaded and checked now by calling InitializeTlsAfterBind, not at the
    // first client connection (which may be too late)
    procedure WaitStarted(Seconds: integer; const CertificateFile: TFileName;
      const PrivateKeyFile: TFileName = ''; const PrivateKeyPassword: RawUtf8 = '';
      const CACertificatesFile: TFileName = ''); overload;
    /// ensure the HTTP server thread is actually bound to the specified port
    // - for hsoEnableTls support, allow to specify all server-side TLS
    // events, including callbacks, as supported by OpenSSL
    // - will raise EHttpServer if the server did not start properly, e.g.
    // could not bind the port within the supplied time
    procedure WaitStarted(Seconds: integer = 30; TLS: PNetTlsContext = nil);
      overload;
    /// ensure the server thread is bound as self-signed HTTPS server
    // - wrap InitNetTlsContextSelfSignedServer() and WaitStarted() with
    // some temporary key files, which are deleted once started
    // - as used e.g. by TRestHttpServer for secTLSSelfSigned
    procedure WaitStartedHttps(Seconds: integer = 30;
      UsePreComputed: boolean = false);
    /// could be called after WaitStarted(seconds,'','','') to setup TLS
    // - validate Sock.TLS.CertificateFile/PrivateKeyFile/PrivatePassword
    // - otherwise TLS is initialized at first incoming connection, which
    // could be too late in case of invalid Sock.TLS parameters
    procedure InitializeTlsAfterBind;
    /// remove any previous authorization, i.e. any previous SetAuthorizeBasic /
    // SetAuthorizeDigest / SetAuthorizeKerberos call
    procedure SetAuthorizeNone;
    /// allow optional BASIC authentication for some URIs via a callback
    // - if OnBeforeBody returns 401, the OnBasicAuth callback will be executed
    // to negotiate Basic authentication with the client
    procedure SetAuthorizeBasic(const BasicRealm: RawUtf8;
      const OnBasicAuth: TOnHttpServerBasicAuth); overload;
    /// allow optional BASIC authentication for some URIs via IBasicAuthServer
    // - if OnBeforeBody returns 401, Digester.OnCheckCredential will
    // be called to negotiate Basic authentication with the client
    // - the supplied Digester will be owned by this instance: it could be
    // either a TDigestAuthServerFile with its own storage, or a
    // TDigestAuthServerMem instance expecting manual SetCredential() calls
    procedure SetAuthorizeBasic(const Basic: IBasicAuthServer); overload;
    /// allow optional DIGEST authentication for some URIs
    // - if OnBeforeBody returns 401, Digester.ServerInit and ServerAuth will
    // be called to negotiate Digest authentication with the client
    // - the supplied Digester will be owned by this instance - typical
    // use is with a TDigestAuthServerFile
    procedure SetAuthorizeDigest(const Digest: IDigestAuthServer);
    /// allow optional NEGOTIATE authentication for some URIs via Kerberos
    // - will use mormot.lib.sspi or mormot.lib.gssapi
    // - if OnBeforeBody returns 401, Kerberos will be used to authenticate
    procedure SetAuthorizeNegotiate;
    /// set after a call to SetAuthDigest/SetAuthBasic/SetAuthorizeNegotiate
    property Authorize: THttpServerRequestAuthentication
      read fAuthorize;
    /// set after a call to SetAuthDigest/SetAuthBasic
    // - return nil if no such call was made, or not with a TDigestAuthServerMem
    // - return a TDigestAuthServerMem so that SetCredential/GetUsers are available
    function AuthorizeServerMem: TDigestAuthServerMem;
    /// enable NGINX X-Accel internal redirection for STATICFILE_CONTENT_TYPE
    // - will define internally a matching OnSendFile event handler
    // - generating "X-Accel-Redirect: " header, trimming any supplied left
    // case-sensitive file name prefix, e.g. with NginxSendFileFrom('/var/www'):
    // $ # Will serve /var/www/protected_files/myfile.tar.gz
    // $ # When passed URI /protected_files/myfile.tar.gz
    // $ location /protected_files {
    // $  internal;
    // $  root /var/www;
    // $ }
    // - call this method several times to register several folders
    procedure NginxSendFileFrom(const FileNameLeftTrim: TFileName);
    /// milliseconds delay to reject a connection due to too long header retrieval
    // - default is 0, i.e. not checked (typical behind a reverse proxy)
    property HeaderRetrieveAbortDelay: cardinal
      read fHeaderRetrieveAbortDelay write fHeaderRetrieveAbortDelay;
    /// the low-level thread execution thread
    property ExecuteState: THttpServerExecuteState
      read GetExecuteState;
    /// access to the main server low-level Socket
    // - it's a raw TCrtSocket, which only need a socket to be bound, listening
    // and accept incoming request
    // - for THttpServer inherited class, will own its own instance, then
    // THttpServerSocket/THttpServerResp are created for every connection
    // - for THttpAsyncServer inherited class, redirect to TAsyncServer.fServer
    property Sock: TCrtSocket
      read fSock;
  published
    /// the bound TCP port, as specified to Create() constructor
    property SockPort: RawUtf8
      read fSockPort;
    /// time, in milliseconds, for the HTTP/1.1 connections to be kept alive
    // - default is 30000 ms, i.e. 30 seconds
    // - setting 0 here (or in KeepAliveTimeOut constructor parameter) will
    // disable keep-alive, and fallback to HTTP.1/0 for all incoming requests
    // (may be a good idea e.g. behind a NGINX reverse proxy)
    // - see THttpApiServer.SetTimeOutLimits(aIdleConnection) parameter
    property ServerKeepAliveTimeOut: cardinal
      read fServerKeepAliveTimeOut write fServerKeepAliveTimeOut;
    /// if we should search for local .gz cached file when serving static files
    property RegisterCompressGzStatic: boolean
      read GetRegisterCompressGzStatic write SetRegisterCompressGzStatic;
    /// how many HTTP connections have been closed
    property StatHeaderClosed: integer
      index grClosed read GetStat;
    /// how many invalid HTTP headers raised an exception
    property StatHeaderException: integer
      index grException read GetStat;
    /// how many HTTP requests pushed more than MaximumAllowedContentLength bytes
    property StatOversizedPayloads: integer
      index grOversizedPayload read GetStat;
    /// how many HTTP requests were rejected by the OnBeforeBody event handler
    property StatRejected: integer
      index grRejected read GetStat;
    /// how many HTTP requests were intercepted by the OnHeaderParser event handler
    property StatIntercepted: integer
      index grIntercepted read GetStat;
    /// how many HTTP requests were rejected after HeaderRetrieveAbortDelay timeout
    property StatHeaderTimeout: integer
      index grTimeout read GetStat;
    /// how many HTTP headers have been processed
    property StatHeaderProcessed: integer
      index grHeaderReceived read GetStat;
    /// how many HTTP bodies have been processed
    property StatBodyProcessed: integer
      index grBodyReceived read GetStat;
    /// how many HTTP 401 "WWW-Authenticate:" responses have been returned
    property StatWwwAuthenticate: integer
      index grWwwAuthenticate read GetStat;
    /// how many HTTP connections were upgraded e.g. to WebSockets
    property StatUpgraded: integer
      index grUpgraded read GetStat;
    /// how many HTTP connections have been not accepted by hsoBan40xIP option
    property StatBanned: integer
      index grBanned read GetStat;
  end;

  /// meta-class of our THttpServerSocketGeneric classes
  // - typically implemented by THttpServer, TWebSocketServer,
  // TWebSocketServerRest or THttpAsyncServer classes
  THttpServerSocketGenericClass = class of THttpServerSocketGeneric;

  /// called from THttpServerSocket.GetRequest before OnBeforeBody
  // - this THttpServer-specific callback allow quick and dirty action on the
  // raw socket, to bypass the whole THttpServer.Process high-level action
  // - should return grRejected/grIntercepted if the action has been handled as
  // error or success, and response has been sent directly via
  // ClientSock.SockSend/SockSendFlush (as HTTP/1.0) by this handler
  // - should return grHeaderReceived to continue as usual with THttpServer.Process
  TOnHttpServerHeaderParsed = function(
    ClientSock: THttpServerSocket): THttpServerSocketGetRequestResult of object;

  /// main HTTP server Thread using the standard Sockets API (e.g. WinSock)
  // - bind to a port and listen to incoming requests
  // - assign this requests to THttpServerResp threads from a ThreadPool
  // - it implements a HTTP/1.1 compatible server, according to RFC 2068 specifications
  // - if the client is also HTTP/1.1 compatible, KeepAlive connection is handled:
  //  multiple requests will use the existing connection and thread;
  //  this is faster and uses less resources, especialy under Windows
  // - a Thread Pool is used internally to speed up HTTP/1.0 connections - a
  // typical use, under Linux, is to run this class behind a NGINX frontend,
  // configured as https reverse proxy, leaving default "proxy_http_version 1.0"
  // and "proxy_request_buffering on" options for best performance, and
  // setting KeepAliveTimeOut=0 in the THttpServer.Create constructor
  // - consider using THttpAsyncServer from mormot.net.async if a very high
  // number of concurrent connections is expected, e.g. if using HTTP/1.0 behind
  // a https reverse proxy is not an option
  // - under Windows, will trigger the firewall UAC popup at first run
  // - don't forget to use Free method when you are finished
  // - a typical HTTPS server usecase could be:
  // $ fHttpServer := THttpServer.Create('443', nil, nil, '', 32, 30000, [hsoEnableTls]);
  // $ fHttpServer.WaitStarted('cert.pem', 'privkey.pem', '');  // cert.pfx for SSPI
  // $ // now certificates will be initialized and used
  THttpServer = class(THttpServerSocketGeneric)
  protected
    fThreadPool: TSynThreadPoolTHttpServer;
    fInternalHttpServerRespList: TSynObjectListLocked;
    fSocketClass: THttpServerSocketClass;
    fThreadRespClass: THttpServerRespClass;
    fHttpQueueLength: cardinal;
    fServerConnectionCount: integer;
    fServerConnectionActive: integer;
    fServerSendBufferSize: integer;
    fExecuteState: THttpServerExecuteState;
    fMonoThread: boolean;
    fOnHeaderParsed: TOnHttpServerHeaderParsed;
    fBanned: THttpAcceptBan; // for hsoBan40xIP
    fOnAcceptIdle: TOnPollSocketsIdle;
    function GetExecuteState: THttpServerExecuteState; override;
    function GetHttpQueueLength: cardinal; override;
    procedure SetHttpQueueLength(aValue: cardinal); override;
    function GetConnectionsActive: cardinal; override;
    /// server main loop - don't change directly
    procedure Execute; override;
    /// this method is called on every new client connection, i.e. every time
    // a THttpServerResp thread is created with a new incoming socket
    procedure OnConnect; virtual;
    /// this method is called on every client disconnection to update stats
    procedure OnDisconnect; virtual;
    /// override this function in order to low-level process the request;
    // default process is to get headers, and call public function Request
    procedure Process(ClientSock: THttpServerSocket;
      ConnectionID: THttpServerConnectionID; ConnectionThread: TSynThread); virtual;
  public
    /// create a socket-based HTTP Server, ready to be bound and listening on a port
    // - ServerThreadPoolCount < 0 would use a single thread to rule them all
    // - ServerThreadPoolCount = 0 would create one thread per connection
    // - ServerThreadPoolCount > 0 would leverage the thread pool, and create
    // one thread only for kept-alive or upgraded connections
    constructor Create(const aPort: RawUtf8;
      const OnStart, OnStop: TOnNotifyThread; const ProcessName: RawUtf8;
      ServerThreadPoolCount: integer = 32; KeepAliveTimeOut: integer = 30000;
      ProcessOptions: THttpServerOptions = []); override;
    /// release all memory and handlers
    destructor Destroy; override;
    /// low-level callback called before OnBeforeBody and allow quick execution
    // directly from THttpServerSocket.GetRequest
    property OnHeaderParsed: TOnHttpServerHeaderParsed
      read fOnHeaderParsed write fOnHeaderParsed;
    /// low-level callback called every few seconds of inactive Accept()
    // - is called every 5 seconds by default, but could be every second
    // if hsoBan40xIP option (i.e. the Banned property) has been set
    // - on Windows, requires some requests to trigger the event, because it
    // seems that accept() has timeout only on POSIX systems
    property OnAcceptIdle: TOnPollSocketsIdle
      read fOnAcceptIdle write fOnAcceptIdle;
  published
    /// will contain the current number of connections to the server
    property ServerConnectionActive: integer
      read fServerConnectionActive write fServerConnectionActive;
    /// will contain the total number of connections to the server
    // - it's the global count since the server started
    property ServerConnectionCount: integer
      read fServerConnectionCount write fServerConnectionCount;
    /// the associated thread pool
    // - may be nil if ServerThreadPoolCount was 0 on constructor
    property ThreadPool: TSynThreadPoolTHttpServer
      read fThreadPool;
    /// set if hsoBan40xIP has been defined
    // - indicates e.g. how many accept() have been rejected from their IP
    // - you can customize its behavior once the server is started by resetting
    // its Seconds/Max/WhiteIP properties, before any connections are made
    property Banned: THttpAcceptBan
      read fBanned;
  end;


const
  // kept-alive or big HTTP requests will create a dedicated THttpServerResp
  // - each thread reserves 2 MB of memory so it may break the server
  // - keep the value to a decent number, to let resources be constrained up to 1GB
  // - is the default value to TSynThreadPoolTHttpServer.MaxBodyThreadCount
  THREADPOOL_MAXWORKTHREADS = 512;

  /// if HTTP body length is bigger than 16 MB, creates a dedicated THttpServerResp
  // - is the default value to TSynThreadPoolTHttpServer.BigBodySize
  THREADPOOL_BIGBODYSIZE = 16 * 1024 * 1024;

function ToText(res: THttpServerSocketGetRequestResult): PShortString; overload;


{ ******************** THttpPeerCache Local Peer-to-peer Cache }

{
  TODO:
  - Daemon/Service background mode for the mget tool
  - Asymmetric security using ECDH shared secret? use HTTPS instead?
  - Frame signature using ECDHE with ephemeral keys? use HTTPS instead?
  - Allow binding to several network interfaces? (e.g. wifi to/from ethernet)
}

type
  /// the content of a binary THttpPeerCacheMessage
  // - could eventually be extended in the future for frame versioning
  THttpPeerCacheMessageKind = (
    pcfPing,
    pcfPong,
    pcfRequest,
    pcfResponseNone,
    pcfResponseOverloaded,
    pcfResponsePartial,
    pcfResponseFull,
    pcfBearer,
    pcfBearerDirect);

  /// one UDP request frame used during THttpPeerCache discovery
  // - requests and responses have the same binary layout
  // - some fields may be void or irrelevant, and the structure is padded
  // with random up to 192 bytes
  // - over the wire, packets are encrypted and authenticated via AES-GCM-128
  // with an ending salted checksum for quick anti-fuzzing
  THttpPeerCacheMessage = packed record
    /// the content of this binary frame
    Kind: THttpPeerCacheMessageKind;
    /// 32-bit sequence number
    Seq: cardinal;
    /// the UUID of the Sender
    Uuid: TGuid;
    /// the Operating System of the Sender
    Os: TOperatingSystemVersion;
    /// the local IPv4 which sent this frame
    // - e.g. 192.168.1.1
    IP4: cardinal;
    /// the destination IPv4 of this frame
    // - contains 0 for a broadcast
    // - allows to filter response frames when broadcasted on POSIX
    DestIP4: cardinal;
    /// the IPv4 network mask of the local network interface
    // - e.g. 255.255.255.0
    MaskIP4: cardinal;
    /// the IPv4 broadcast address the local network interface
    // - e.g. 192.168.1.255
    BroadcastIP4: cardinal;
    /// the link speed (in Mbits per second) of the local network interface
    Speed: cardinal;
    /// the hardware model of this network interface
    Hardware: TMacAddressKind;
    /// the local UnixTimeMinimalUtc value
    Timestamp: cardinal;
    /// number of background download connections currently on this server
    Connections: word;
    /// up to 512-bit of binary Hash (and algo) of the requested file content
    Hash: THashDigest;
    /// the known full size of this file
    Size: Int64;
    /// the Range offset of the requested file content
    RangeStart: Int64;
    /// the Range ending position of the file content (included)
    RangeEnd: Int64;
    /// some internal state representation, e.g. sent back as pcfBearer
    Opaque: QWord;
    /// define the kind of content in the padding block - always 0 by now
    PaddingVersion: byte;
    /// some random padding up to 192 bytes, used for future content revisions
    // - e.g. for a TEccPublicKey (ECDHE) and additional fields
    // - using random enhances AES-GCM obfuscation by making it unpredictable
    Padding: array[0 .. 41] of byte;
  end;
  THttpPeerCacheMessageDynArray = array of THttpPeerCacheMessage;

  /// each THttpPeerCacheSettings.Options item
  // - pcoCacheTempSubFolders will create 16 sub-folders (from first 0-9/a-z
  // hash nibble) within CacheTempPath to reduce filesystem fragmentation
  // - pcoUseFirstResponse will accept the first positive response, and don't
  // wait for the BroadcastTimeoutMS delay for all responses to be received
  // - pcoTryLastPeer will first check the latest peer with HTTP/TCP before
  // making any broadcast - to be used if the files are likely to come in batch;
  // can be forced by TWGetAlternateOptions from a given WGet() call
  // - pcoTryAllPeers will try up to the best 10 braodcast responses, before
  // falling back to the main server
  // - pcoBroadcastNotAlone will disable broadcasting for up to one second if
  // no response at all was received within BroadcastTimeoutMS delay
  // - pcoNoServer disable the local UDP/HTTP servers and acts as a pure client
  // - pcoNoBanIP disable the 4 seconds IP banishment mechanism at HTTP level;
  // set RejectInstablePeersMin = 0 to disable banishment at UDP level
  // - pcoSelfSignedHttps enables HTTPS communication with a self-signed server
  // (warning: this option should be set on all peers, clients and servers) -
  // as an alternative, you could set THttpPeerCache.ServerTls/ClientTls props
  // - pcoVerboseLog will log all details, e.g. raw UDP frames
  // - pcoHttpDirect extends the HTTP endpoint to initiate a download process
  // from localhost, and return the cached content (used e.g. as proxy + cache)
  THttpPeerCacheOption = (
    pcoCacheTempSubFolders,
    pcoUseFirstResponse,
    pcoTryLastPeer,
    pcoTryAllPeers,
    pcoBroadcastNotAlone,
    pcoNoServer,
    pcoNoBanIP,
    pcoSelfSignedHttps,
    pcoVerboseLog,
    pcoHttpDirect);

  /// THttpPeerCacheSettings.Options values
  THttpPeerCacheOptions = set of THttpPeerCacheOption;

  /// define how THttpPeerCache handles its process
  THttpPeerCacheSettings = class(TSynPersistent)
  protected
    fPort: TNetPort;
    fInterfaceFilter: TMacAddressFilter;
    fOptions: THttpPeerCacheOptions;
    fLimitMBPerSec, fLimitClientCount,
    fBroadcastTimeoutMS, fBroadcastMaxResponses, fTryAllPeersCount,
    fHttpTimeoutMS, fRejectInstablePeersMin,
    fCacheTempMaxMB, fCacheTempMaxMin,
    fCacheTempMinBytes, fCachePermMinBytes: integer;
    fInterfaceName, fUuid: RawUtf8;
    fCacheTempPath, fCachePermPath: TFileName;
  public
    /// set the default settings
    // - i.e. Port=8099, LimitMBPerSec=10, LimitClientCount=32,
    // RejectInstablePeersMin=4, CacheTempMaxMB=1000, CacheTempMaxMin=60,
    // CacheTempMinBytes=CachePermMinBytes=2048,
    // BroadcastTimeoutMS=10 HttpTimeoutMS=500 and BroadcastMaxResponses=24
    constructor Create; override;
    /// retrieve the network interface fulfilling these settings
    // - network layout may change in real time: this method allows to renew
    // the peer cache instance when a better interface is available
    // - returns '' on success, or an error message
    function GuessInterface(out Mac: TMacAddress): RawUtf8; virtual;
    /// encode a remote URI for pcoHttpDirect download at localhost
    // - returns aDirectUri e.g. as 'http://1.2.3.4:8099/https/microsoft.com/...'
    // (if port is 8099 and Mac.IP is 1.2.3.4) and its aDirectHeaderBearer
    // - aForceTls should map ServerTls.Enabled
    function HttpDirectUri(const aSharedSecret: RawByteString;
      const aRemoteUri, aRemoteHash: RawUtf8;
      out aDirectUri, aDirectHeaderBearer: RawUtf8;
      aForceTls: boolean = false): boolean;
  published
    /// the local port used for UDP and TCP process
    // - value should match on all peers for proper discovery
    // - UDP for discovery, TCP for HTTP/HTTPS content delivery
    // - is 8099 by default, which is unassigned by IANA
    property Port: TNetPort
      read fPort write fPort;
    /// allow to customize the process
    property Options: THttpPeerCacheOptions
      read fOptions write fOptions;
    /// local TMacAddress.Name, Address or IP to be used for UDP and TCP
    // - Name and Address will be searched case-insensitive
    // - IP could be exact or eventually a bitmask pattern (e.g. 192.168.1.255)
    // - if not set, will fallback to the best local makEthernet/makWifi network
    // with broadcasting abilities
    // - matching TMacAddress.IP will be used with the Port property value to
    // bind the TCP/HTTP server and broadcast the UDP discovery packets, so that
    // only this network interface will be involved to find cache peers
    property InterfaceName: RawUtf8
      read fInterfaceName write fInterfaceName;
    /// how GetMacAddress() should find the network, if InterfaceName is not set
    property InterfaceFilter: TMacAddressFilter
      read fInterfaceFilter write fInterfaceFilter;
    /// can limit the peer bandwidth used, in data MegaBytes per second
    // - will be assigned to each TStreamRedirect.LimitPerSecond instance
    // - default is 10 MB/s of data, i.e. aroung 100-125 MBit/s on network
    // - you may set 0 to disable any bandwidth limitation
    // - you may set -1 to use the default TStreamRedirect.LimitPerSecond value
    property LimitMBPerSec: integer
      read fLimitMBPerSec write fLimitMBPerSec;
    /// can limit how many peer clients can be served content at the same time
    // - would prevent any overload, to avoid Denial of Service
    // - default is 32, which means 32 threads with the default THttpServer
    property LimitClientCount: integer
      read fLimitClientCount write fLimitClientCount;
    /// RejectInstablePeersMin will set a delay (in minutes) to ignore any peer
    // which sent invalid UDP frames or HTTP/HTTPS requests
    // - should be a positive small power of two <= 128
    // - default is 4, for a 4 minutes time-to-live of IP banishments
    // - you may set 0 to disable the whole IP ban safety mechanism at UDP level
    // - use pcoNoBanIP option to disable the IP ban mechanism at HTTP level
    property RejectInstablePeersMin: integer
      read fRejectInstablePeersMin write fRejectInstablePeersMin;
    /// how many milliseconds UDP broadcast should wait for a response
    // - default is 10 ms which seems enough on a local network
    // - on Windows, this value is indicative, likely to have 15ms resolution
    property BroadcastTimeoutMS: integer
      read fBroadcastTimeoutMS write fBroadcastTimeoutMS;
    /// how many responses UDP broadcast should take into account
    // - default is 24
    property BroadcastMaxResponses: integer
      read fBroadcastMaxResponses write fBroadcastMaxResponses;
    /// how many of the best responses should pcoTryAllPeers also try
    // - default is 10
    property TryAllPeersCount: integer
      read fTryAllPeersCount write fTryAllPeersCount;
    /// the socket level timeout for HTTP requests
    // - default to low 500 ms because should be local
    property HttpTimeoutMS: integer
      read fHttpTimeoutMS write fHttpTimeoutMS;
    /// location of the temporary cached files, available for remote requests
    // - the files are cached using their THashDigest values as filename
    // - this folder will be purged according to CacheTempMaxMB/CacheTempMaxMin
    // - if this value equals '', or pcoNoServer is defined in Options,
    // temporary caching would be disabled
    property CacheTempPath: TFileName
      read fCacheTempPath write fCacheTempPath;
    /// above how many bytes the peer network should be asked for a temporary file
    // - there is no size limitation if the file is already in the temporary
    // cache, or if the waoNoMinimalSize option is specified by WGet()
    // - default is 2048 bytes, i.e. 2KB
    property CacheTempMinBytes: integer
      read fCacheTempMinBytes  write fCacheTempMinBytes;
    /// after how many MB in CacheTempPath the folder should be cleaned
    // - default is 1000, i.e. just below 1 GB
    // - THttpPeerCache.Create will also always ensure that this value won't
    // take more than 25% of the CacheTempPath folder available space
    property CacheTempMaxMB: integer
      read fCacheTempMaxMB write fCacheTempMaxMB;
    /// after how many minutes files in CacheTempPath could be cleaned
    // - i.e. the Time-To-Live (TTL) of temporary files
    // - default is 60 minutes, i.e. 1 hour
    property CacheTempMaxMin: integer
      read fCacheTempMaxMin write fCacheTempMaxMin;
    /// location of the permanent cached files, available for remote requests
    // - in respect to CacheTempPath, this folder won't be purged
    // - the files are cached using their THashDigest values as filename
    // - if this value equals '', or pcoNoServer is defined in Options,
    // permanent caching would be disabled
    property CachePermPath: TFileName
      read fCachePermPath write fCachePermPath;
    /// above how many bytes the peer network should be asked for a permanent file
    // - there is no size limitation if the file is already in the permanent
    // cache, or if the waoNoMinimalSize option is specified by WGet()
    // - default is 2048 bytes, i.e. 2KB, which is just two network MTU trips
    property CachePermMinBytes: integer
      read fCachePermMinBytes  write fCachePermMinBytes;
    /// allow to customize the UUID used to identify this node
    // - instead of the default GetComputerUuid() from SMBios
    property Uuid: RawUtf8
      read fUuid write fUuid;
  end;

  /// information about THttpPeerCrypt.MessageDecode() success
  THttpPeerCryptMessageDecode = (
    mdOk,
    mdBLen,
    mdB64,
    mdBearer,
    mdLen,
    mdCrc,
    mdAes,
    mdSeq,
    mdKind,
    mdHw,
    mdAlgo);

  /// abstract parent to THttpPeerCache for its cryptographic core
  THttpPeerCrypt = class(TInterfacedPersistent)
  protected
    fAesSafe: TLightLock; // topmost to ensure proper aarch64 alignment
    fClientSafe: TLightLock; // paranoid - only if unproperly used
    fSettings: THttpPeerCacheSettings;
    fSharedMagic, fFrameSeqLow: cardinal;
    fFrameSeq: integer;
    fIP4, fMaskIP4, fBroadcastIP4, fClientIP4, fLastNetworkTix: cardinal;
    fAesEnc, fAesDec: TAesGcmAbstract;
    fLog: TSynLogClass;
    fPort, fIpPort: RawUtf8;
    fClient: THttpClientSocket;
    fInstable: THttpAcceptBan; // from Settings.RejectInstablePeersMin
    fMac: TMacAddress;
    fUuid: TGuid;
    fServerTls, fClientTls: TNetTlsContext;
    procedure AfterSettings; virtual;
    function CurrentConnections: integer; virtual;
    procedure MessageInit(aKind: THttpPeerCacheMessageKind; aSeq: cardinal;
      out aMsg: THttpPeerCacheMessage); virtual;
    function MessageEncode(const aMsg: THttpPeerCacheMessage): RawByteString;
    function MessageDecode(aFrame: PAnsiChar; aFrameLen: PtrInt;
      out aMsg: THttpPeerCacheMessage): THttpPeerCryptMessageDecode;
    function BearerDecode(
      const aBearerToken: RawUtf8; aExpected: THttpPeerCacheMessageKind;
      out aMsg: THttpPeerCacheMessage): THttpPeerCryptMessageDecode; virtual;
    function LocalPeerRequest(const aRequest: THttpPeerCacheMessage;
      var aResp : THttpPeerCacheMessage; const aUrl: RawUtf8;
      aOutStream: TStreamRedirect; aRetry: boolean): integer;
    function GetUuidText: RawUtf8;
  public
    /// initialize the cryptography of this peer-to-peer node instance
    // - warning: inherited class should also call AfterSettings once
    // fSettings is defined
    constructor Create(const aSharedSecret: RawByteString;
      aServerTls, aClientTls: PNetTlsContext); reintroduce;
    /// finalize this class instance
    destructor Destroy; override;
    /// check if the network interface defined in Settings did actually change
    // - you may want to recreate a peer-cache to track the new network layout
    function NetworkInterfaceChanged: boolean;
    /// encode a remote URI for pcoHttpDirect download at localhost
    // - aSharedSecret should match the Create() value
    // - returns aDirectUri as '/https/microsoft.com/...' and aDirectHeaderBearer
    class function HttpDirectUri(const aSharedSecret: RawByteString;
      const aRemoteUri, aRemoteHash: RawUtf8;
      out aDirectUri, aDirectHeaderBearer: RawUtf8): boolean;
    /// decode a remote URI for pcoHttpDirect download at localhost
    // - as previously encoded by HttpDirectUri() class function
    class function HttpDirectUriReconstruct(P: PUtf8Char;
      out Decoded: TUri): boolean;
    /// optional TLS options for the peer HTTPS server
    // - e.g. to set a custom certificate for this peer
    // - when ServerTls.Enabled is set, ClientTls.Enabled and other params should match
    property ServerTls: TNetTlsContext
      read fServerTls write fServerTls;
    /// optional TLS options for the peer HTTPS client
    // - e.g. set ClientTls.OnPeerValidate to verify a peer ServerTls certificate
    // - when ClientTls.Enabled is set, ServerTls.Enabled and other params should match
    property ClientTls: TNetTlsContext
      read fClientTls write fClientTls;
    /// the network interface used for UDP and TCP process
    // - the main fields are published below as Network* properties
    property Mac: TMacAddress
      read fMac;
  published
    /// define how this instance handles its process
    property Settings: THttpPeerCacheSettings
      read fSettings;
    /// which network interface is used for UDP and TCP process
    property NetworkInterface: RawUtf8
      read fMac.Name;
    /// the local IP address used for UDP and TCP process
    property NetworkIP: RawUtf8
      read fMac.IP;
    /// the IP used for UDP and TCP process broadcast
    property NetworkBroadcast: RawUtf8
      read fMac.Broadcast;
    property Uuid: RawUtf8
      read GetUuidText;
  end;

  /// exception class raised on THttpPeerCache issues
  EHttpPeerCache = class(ESynException);

  THttpPeerCache = class;

  /// background UDP server thread, associated to a THttpPeerCache instance
  THttpPeerCacheThread = class(TUdpServerThread)
  protected
    fOwner: THttpPeerCache;
    fMsg: THttpPeerCacheMessage;
    fSent, fResponses: integer;
    fRespSafe: TLightLock;
    fResp: THttpPeerCacheMessageDynArray;
    fRespCount: integer;
    fCurrentSeq: cardinal;
    fBroadcastEvent: TSynEvent;   // e.g. for pcoUseFirstResponse
    fBroadcastAddr: TNetAddr;     // from fBroadcastIP4 + fSettings.Port
    fBroadcastSafe: TOSLightLock; // non-reentrant, to serialize Broadcast()
    fBroadcastIpPort: RawUtf8;
    procedure OnFrameReceived(len: integer; var remote: TNetAddr); override;
    procedure OnIdle(tix64: Int64); override;
    procedure OnShutdown; override; // = Destroy
    function Broadcast(const aReq: THttpPeerCacheMessage;
      out aAlone: boolean): THttpPeerCacheMessageDynArray;
    function AddResponseAndDone(const aMessage: THttpPeerCacheMessage): boolean;
    function GetResponses(aSeq: cardinal): THttpPeerCacheMessageDynArray;
  public
    /// initialize the background UDP server thread
    constructor Create(Owner: THttpPeerCache); reintroduce;
    /// finalize this instance
    destructor Destroy; override;
  published
    property Sent: integer
      read fSent;
  end;

  THttpPeerCacheLocalFileName = set of (
    lfnSetDate,
    lfnEnsureDirectoryExists);

  /// implement a local peer-to-peer download cache via UDP and TCP
  // - UDP broadcasting is used for local peers discovery
  // - TCP is bound to a local THttpServer/THttpAsyncServer content delivery
  // - will maintain its own local folders of cached files, stored by hash
  THttpPeerCache = class(THttpPeerCrypt, IWGetAlternate)
  protected
    fHttpServer: THttpServerGeneric;
    fUdpServer: THttpPeerCacheThread;
    fPermFilesPath, fTempFilesPath: TFileName;
    fTempFilesMaxSize: Int64; // from Settings.CacheTempMaxMB
    fTempCurrentSize: Int64;
    fTempFilesDeleteDeprecatedTix, fInstableTix, fBroadcastTix: cardinal;
    fSettingsOwned, fVerboseLog: boolean;
    fFilesSafe: TOSLock; // concurrent cached files access
    fPartials: THttpPartials;
    // most of these internal methods are virtual for proper customization
    procedure StartHttpServer(aHttpServerClass: THttpServerSocketGenericClass;
      aHttpServerThreadCount: integer; const aIP: RawUtf8); virtual;
    function CurrentConnections: integer; override;
    function ComputeFileName(const aHash: THashDigest): TFileName; virtual;
    function PermFileName(const aFileName: TFileName;
      aFlags: THttpPeerCacheLocalFileName): TFileName; virtual;
    function LocalFileName(const aMessage: THttpPeerCacheMessage;
      aFlags: THttpPeerCacheLocalFileName;
      aFileName: PFileName; aSize: PInt64): integer;
    function CachedFileName(const aParams: THttpClientSocketWGet;
      aFlags: THttpPeerCacheLocalFileName;
      out aLocal: TFileName; out isTemp: boolean): boolean;
    function TooSmallFile(const aParams: THttpClientSocketWGet;
      aSize: Int64; const aCaller: shortstring): boolean;
    function PartialFileName(const aMessage: THttpPeerCacheMessage;
      aHttp: PHttpRequestContext; aFileName: PFileName; aSize: PInt64): integer;
    function Check(Status: THttpPeerCryptMessageDecode;
      const Ctxt: ShortString; const Msg: THttpPeerCacheMessage): boolean;
  public
    /// initialize this peer-to-peer cache instance
    // - any supplied aSettings should be owned by the caller (e.g from a main
    // settings class instance)
    // - aSharedSecret is used to cipher and authenticate each UDP frame between
    // all peer nodes, and also generate HTTP authentication bearers
    // - if aSettings = nil, default values will be used by this instance
    // - you can supply THttpAsyncServer class to replace default THttpServer
    // - may raise some exceptions if the HTTP server cannot be started
    constructor Create(aSettings: THttpPeerCacheSettings;
      const aSharedSecret: RawByteString;
      aHttpServerClass: THttpServerSocketGenericClass = nil;
      aHttpServerThreadCount: integer = 2; aLogClass: TSynLogClass = nil;
      aServerTls: PNetTlsContext = nil; aClientTls: PNetTlsContext = nil); reintroduce;
    /// finalize this peer-to-peer cache instance
    destructor Destroy; override;
    /// IWGetAlternate main processing method, as used by THttpClientSocketWGet
    // - will transfer Sender.Server/Port/RangeStart/RangeEnd into OutStream
    // - OutStream.LimitPerSecond will be overriden during the call
    // - could return 0 to fallback to a regular GET (e.g. not cached)
    function OnDownload(Sender: THttpClientSocket;
      var Params: THttpClientSocketWGet; const Url: RawUtf8;
      ExpectedFullSize: Int64; OutStream: TStreamRedirect): integer; virtual;
    /// IWGetAlternate main processing method, as used by THttpClientSocketWGet
    // - if a file has been downloaded from the main repository, this method
    // should be called to copy the content into this instance files cache
    procedure OnDowloaded(var Params: THttpClientSocketWGet;
      const Partial: TFileName; PartialID: integer); virtual;
    /// IWGetAlternate main processing method, as used by THttpClientSocketWGet
    // - OnDownload() may have returned corrupted data: local cache file is
    // likely to be deleted, for safety
    procedure OnDownloadFailed(const Params: THttpClientSocketWGet);
    /// IWGetAlternate main processing method, as used by THttpClientSocketWGet
    // - make this .part file available as pcfResponsePartial
    // - returns PartialID > 0 sequence
    function OnDownloading(const Params: THttpClientSocketWGet;
      const Partial: TFileName; ExpectedFullSize: Int64): THttpPartialID;
    /// IWGetAlternate main processing method, as used by THttpClientSocketWGet
    /// notify the alternate download implementation that OnDownloading() failed
    // - e.g. THttpPeerCache is likely to abort publishing this partial file
    procedure OnDownloadingFailed(ID: THttpPartialID);
    /// broadcast a pcfPing on the network interface and return the responses
    function Ping: THttpPeerCacheMessageDynArray;
    /// method called by the HttpServer before any request is processed
    // - will reject anything but a GET with a proper bearer, from the right IP
    function OnBeforeBody(var aUrl, aMethod, aInHeaders,
      aInContentType, aRemoteIP, aBearerToken: RawUtf8; aContentLength: Int64;
      aFlags: THttpServerRequestFlags): cardinal; virtual;
    /// method called by the HttpServer to process a request
    // - statically serve a local file from decoded bearer hash
    function OnRequest(Ctxt: THttpServerRequestAbstract): cardinal; virtual;
    /// is called on a regular basis for background regular process
    // - is called from THttpPeerCacheThread.OnIdle
    // - e.g. to implement optional CacheTempMaxMin disk space release,
    // actually reading and purging the CacheTempPath folder every minute
    // - could call Instable.DoRotate every minute to refresh IP banishments
    procedure OnIdle(tix64: Int64);
  published
    /// the associated HTTP/HTTPS server delivering cached context
    property HttpServer: THttpServerGeneric
      read fHttpServer;
    /// the current state of banned IP from incorrect UDP/HTTP requests
    // - follow RejectInstablePeersMin settings
    property Instable: THttpAcceptBan
      read fInstable;
  end;

  /// one THttpPeerCache.OnDownload instance
  THttpPeerCacheProcess = class(TSynPersistent)
  protected
    fOwner: THttpPeerCache;
  public
  published
    property Owner: THttpPeerCache
      read fOwner;
  end;

const
  PCF_RESPONSE = [
    pcfPong,
    pcfResponseNone,
    pcfResponseOverloaded,
    pcfResponsePartial,
    pcfResponseFull];

  PEER_CACHE_PATTERN = '*.cache';

function ToText(pcf: THttpPeerCacheMessageKind): PShortString; overload;
function ToText(md: THttpPeerCryptMessageDecode): PShortString; overload;
function ToText(const msg: THttpPeerCacheMessage): shortstring; overload;
  {$ifdef HASINLINE} inline; {$endif}

procedure MsgToShort(const msg: THttpPeerCacheMessage; var result: shortstring);


{$ifdef USEWININET}

{ **************** THttpApiServer HTTP/1.1 Server Over Windows http.sys Module }

type
  THttpApiServer = class;

  THttpApiServers = array of THttpApiServer;

  /// HTTP server using fast http.sys kernel-mode server
  // - The HTTP Server API enables applications to communicate over HTTP without
  // using Microsoft Internet Information Server (IIS). Applications can register
  // to receive HTTP requests for particular URLs, receive HTTP requests, and send
  // HTTP responses. The HTTP Server API includes TLS support so that applications
  // can exchange data over secure HTTP connections without IIS. It is also
  // designed to work with I/O completion ports.
  // - The HTTP Server API is supported on Windows Server 2003 operating systems
  // and on Windows XP with Service Pack 2 (SP2). Be aware that Microsoft IIS 5
  // running on Windows XP with SP2 is not able to share port 80 with other HTTP
  // applications running simultaneously.
  THttpApiServer = class(THttpServerGeneric)
  protected
    /// the internal request queue
    fReqQueue: THandle;
    /// contain list of THttpApiServer cloned instances
    fClones: THttpApiServers;
    // if cloned, fOwner contains the main THttpApiServer instance
    fOwner: THttpApiServer;
    /// list of all registered URL
    fRegisteredUnicodeUrl: TSynUnicodeDynArray;
    fServerSessionID: HTTP_SERVER_SESSION_ID;
    fUrlGroupID: HTTP_URL_GROUP_ID;
    fLogData: pointer;
    fLogDataStorage: TBytes;
    fLoggingServiceName: RawUtf8;
    fAuthenticationSchemes: THttpApiRequestAuthentications;
    fReceiveBufferSize: cardinal;
    procedure SetReceiveBufferSize(Value: cardinal);
    function GetRegisteredUrl: SynUnicode;
    function GetCloned: boolean;
    function GetHttpQueueLength: cardinal; override;
    function GetConnectionsActive: cardinal; override;
    procedure SetHttpQueueLength(aValue: cardinal); override;
    function GetMaxBandwidth: cardinal;
    procedure SetMaxBandwidth(aValue: cardinal);
    function GetMaxConnections: cardinal;
    procedure SetMaxConnections(aValue: cardinal);
    procedure SetOnTerminate(const Event: TOnNotifyThread); override;
    function GetApiVersion: RawUtf8; override;
    function GetLogging: boolean;
    procedure SetServerName(const aName: RawUtf8); override;
    procedure SetOnRequest(const aRequest: TOnHttpServerRequest); override;
    procedure SetOnBeforeBody(const aEvent: TOnHttpServerBeforeBody); override;
    procedure SetOnBeforeRequest(const aEvent: TOnHttpServerRequest); override;
    procedure SetOnAfterRequest(const aEvent: TOnHttpServerRequest); override;
    procedure SetOnAfterResponse(const aEvent: TOnHttpServerAfterResponse); override;
    procedure SetMaximumAllowedContentLength(aMax: Int64); override;
    procedure SetRemoteIPHeader(const aHeader: RawUtf8); override;
    procedure SetRemoteConnIDHeader(const aHeader: RawUtf8); override;
    procedure SetLoggingServiceName(const aName: RawUtf8);
    procedure DoAfterResponse(Ctxt: THttpServerRequest; const Referer: RawUtf8;
      StatusCode: cardinal; Elapsed, Received, Sent: QWord); virtual;
    /// server main loop - don't change directly
    // - will call the Request public virtual method with the appropriate
    // parameters to retrive the content
    procedure Execute; override;
    /// retrieve flags for SendHttpResponse
   // - if response content type is not STATICFILE_CONTENT_TYPE
    function GetSendResponseFlags(Ctxt: THttpServerRequest): integer; virtual;
    /// free resources (for not cloned server)
    procedure DestroyMainThread; virtual;
  public
    /// initialize the HTTP Service
    // - will raise an exception if http.sys is not available e.g. before
    // Windows XP SP2) or if the request queue creation failed
    // - if you override this contructor, put the AddUrl() methods within,
    // and you can set CreateSuspended to FALSE
    // - if you will call AddUrl() methods later, set CreateSuspended to TRUE,
    // then call explicitly the Resume method, after all AddUrl() calls, in
    // order to start the server
    constructor Create(QueueName: SynUnicode = '';
      const OnStart: TOnNotifyThread = nil; const OnStop: TOnNotifyThread = nil;
      const ProcessName: RawUtf8 = ''; ProcessOptions: THttpServerOptions = []);
        reintroduce;
    /// create a HTTP/1.1 processing clone from the main thread
    // - do not use directly - is called during thread pool creation
    constructor CreateClone(From: THttpApiServer); virtual;
    /// release all associated memory and handles
    destructor Destroy; override;
    /// will clone this thread into multiple other threads
    // - could speed up the process on multi-core CPU
    // - will work only if the OnProcess property was set (this is the case
    // e.g. in TRestHttpServer.Create() constructor)
    // - maximum value is 256 - higher should not be worth it
    procedure Clone(ChildThreadCount: integer);
    /// register the URLs to Listen On
    // - e.g. AddUrl('root','888')
    // - aDomainName could be either a fully qualified case-insensitive domain
    // name, an IPv4 or IPv6 literal string, or a wildcard ('+' will bound
    // to all domain names for the specified port, '*' will accept the request
    // when no other listening hostnames match the request for that port)
    // - return 0 (NO_ERROR) on success, an error code if failed: under Vista
    // and Seven, you could have ERROR_ACCESS_DENIED if the process is not
    // running with enough rights (by default, UAC requires administrator rights
    // for adding an URL to http.sys registration list) - solution is to call
    // the THttpApiServer.AddUrlAuthorize class method during program setup
    // - if this method is not used within an overridden constructor, default
    // Create must have be called with CreateSuspended = TRUE and then call the
    // Resume method after all Url have been added
    // - if aRegisterUri is TRUE, the URI will be registered (need adminitrator
    // rights) - default is FALSE, as defined by Windows security policy
    function AddUrl(const aRoot, aPort: RawUtf8; Https: boolean = false;
      const aDomainName: RawUtf8 = '*'; aRegisterUri: boolean = false;
      aContext: Int64 = 0): integer;
    /// un-register the URLs to Listen On
    // - this method expect the same parameters as specified to AddUrl()
    // - return 0 (NO_ERROR) on success, an error code if failed (e.g.
    // -1 if the corresponding parameters do not match any previous AddUrl)
    function RemoveUrl(const aRoot, aPort: RawUtf8; Https: boolean = false;
      const aDomainName: RawUtf8 = '*'): integer;
    /// will authorize a specified URL prefix
    // - will allow to call AddUrl() later for any user on the computer
    // - if aRoot is left '', it will authorize any root for this port
    // - must be called with Administrator rights: this class function is to be
    // used in a Setup program for instance, especially under Vista or Seven,
    // to reserve the Url for the server
    // - add a new record to the http.sys URL reservation store
    // - return '' on success, an error message otherwise
    // - will first delete any matching rule for this URL prefix
    // - if OnlyDelete is true, will delete but won't add the new authorization;
    // in this case, any error message at deletion will be returned
    class function AddUrlAuthorize(const aRoot, aPort: RawUtf8; Https: boolean = false;
      const aDomainName: RawUtf8 = '*'; OnlyDelete: boolean = false): string;
    /// will register a compression algorithm
    // - overridden method which will handle any cloned instances
    procedure RegisterCompress(aFunction: THttpSocketCompress;
      aCompressMinSize: integer = 1024; aPriority: integer = 10); override;
    /// access to the internal THttpApiServer list cloned by this main instance
    // - as created by Clone() method
    property Clones: THttpApiServers
      read fClones;
  public { HTTP API 2.0 methods and properties }
    /// can be used to check if the HTTP API 2.0 is available
    function HasApi2: boolean;
    /// enable HTTP API 2.0 advanced timeout settings
    // - all those settings are set for the current URL group
    // - will raise an EHttpApiServer exception if the old HTTP API 1.x is used
    // so you should better test the availability of the method first:
    // ! if aServer.HasApi2 then
    // !   SetTimeOutLimits(....);
    // - aEntityBody is the time, in seconds, allowed for the request entity
    // body to arrive - default value is 2 minutes
    // - aDrainEntityBody is the time, in seconds, allowed for the HTTP Server
    // API to drain the entity body on a Keep-Alive connection - default value
    // is 2 minutes
    // - aRequestQueue is the time, in seconds, allowed for the request to
    // remain in the request queue before the application picks it up - default
    // value is 2 minutes
    // - aIdleConnection is the time, in seconds, allowed for an idle connection;
    // is similar to THttpServer.ServerKeepAliveTimeOut - default value is
    // 2 minutes
    // - aHeaderWait is the time, in seconds, allowed for the HTTP Server API
    // to parse the request header - default value is 2 minutes
    // - aMinSendRate is the minimum send rate, in bytes-per-second, for the
    // response - default value is 150 bytes-per-second
    // - any value set to 0 will set the HTTP Server API default value
    procedure SetTimeOutLimits(aEntityBody, aDrainEntityBody,
      aRequestQueue, aIdleConnection, aHeaderWait, aMinSendRate: cardinal);
    /// enable HTTP API 2.0 logging
    // - will raise an EHttpApiServer exception if the old HTTP API 1.x is used
    // so you should better test the availability of the method first:
    // ! if aServer.HasApi2 then
    // !   LogStart(....);
    // - this method won't do anything on the cloned instances, but the main
    // instance logging state will be replicated to all cloned instances
    // - you can select the output folder and the expected logging layout
    // - aSoftwareName will set the optional W3C-only software name string
    // - aRolloverSize will be used only when aRolloverType is hlrSize
    procedure LogStart(const aLogFolder: TFileName;
      aType: THttpApiLoggingType = hltW3C;
      const aSoftwareName: TFileName = '';
      aRolloverType: THttpApiLoggingRollOver = hlrDaily;
      aRolloverSize: cardinal = 0;
      aLogFields: THttpApiLogFields = [hlfDate..hlfSubStatus];
      aFlags: THttpApiLoggingFlags = [hlfUseUtf8Conversion]);
    /// disable HTTP API 2.0 logging
    // - this method won't do anything on the cloned instances, but the main
    // instance logging state will be replicated to all cloned instances
    procedure LogStop;
    /// enable HTTP API 2.0 server-side authentication
    // - once enabled, the client sends an unauthenticated request: it is up to
    // the server application to generate the initial 401 challenge with proper
    // WWW-Authenticate headers; any further authentication steps will be
    // perform in kernel mode, until the authentication handshake is finalized;
    // later on, the application can check the AuthenticationStatus property
    // of THttpServerRequest and its associated AuthenticatedUser value
    // see https://msdn.microsoft.com/en-us/library/windows/desktop/aa364452
    // - will raise an EHttpApiServer exception if the old HTTP API 1.x is used
    // so you should better test the availability of the method first:
    // ! if aServer.HasApi2 then
    // !   SetAuthenticationSchemes(....);
    // - this method will work on the current group, for all instances
    // - see HTTPAPI_AUTH_ENABLE_ALL constant to set all available schemes
    // - optional Realm parameters can be used when haBasic scheme is defined
    // - optional DomainName and Realm parameters can be used for haDigest
    procedure SetAuthenticationSchemes(schemes: THttpApiRequestAuthentications;
      const DomainName: SynUnicode = ''; const Realm: SynUnicode = '');
    /// read-only access to HTTP API 2.0 server-side enabled authentication schemes
    property AuthenticationSchemes: THttpApiRequestAuthentications
      read fAuthenticationSchemes;
    /// read-only access to check if the HTTP API 2.0 logging is enabled
    // - use LogStart/LogStop methods to change this property value
    property Logging: boolean
      read GetLogging;
    /// the current HTTP API 2.0 logging Service name
    // - should be UTF-8 encoded, if LogStart(aFlags=[hlfUseUtf8Conversion])
    // - this value is dedicated to one instance, so the main instance won't
    // propagate the change to all cloned instances
    property LoggingServiceName: RawUtf8
      read fLoggingServiceName write SetLoggingServiceName;
    /// read-only access to the low-level HTTP API 2.0 Session ID
    property ServerSessionID: HTTP_SERVER_SESSION_ID
      read fServerSessionID;
    /// read-only access to the low-level HTTP API 2.0 URI Group ID
    property UrlGroupID: HTTP_URL_GROUP_ID
      read fUrlGroupID;
    /// how many bytes are retrieved in a single call to ReceiveRequestEntityBody
    // - set by default to 1048576, i.e. 1 MB - practical limit is around 20 MB
    // - you may customize this value if you encounter HTTP error HTTP_NOTACCEPTABLE
    // (406) from client, corresponding to an ERROR_NO_SYSTEM_RESOURCES (1450)
    // exception on server side, when uploading huge data content
    property ReceiveBufferSize: cardinal
      read fReceiveBufferSize write SetReceiveBufferSize;
  published
    /// TRUE if this instance is in fact a cloned instance for the thread pool
    property Cloned: boolean
      read GetCloned;
    /// return the list of registered URL on this server instance
    property RegisteredUrl: SynUnicode
      read GetRegisteredUrl;
    /// the maximum allowed bandwidth rate in bytes per second (via HTTP API 2.0)
    // - Setting this value to 0 allows an unlimited bandwidth
    // - by default Windows not limit bandwidth (actually limited to 4 Gbit/sec).
    // - will return 0 if the system does not support HTTP API 2.0 (i.e.
    // under Windows XP or Server 2003)
    property MaxBandwidth: cardinal
      read GetMaxBandwidth write SetMaxBandwidth;
    /// the maximum number of HTTP connections allowed (via HTTP API 2.0)
    // - Setting this value to 0 allows an unlimited number of connections
    // - by default Windows does not limit number of allowed connections
    // - will return 0 if the system does not support HTTP API 2.0 (i.e.
    // under Windows XP or Server 2003)
    property MaxConnections: cardinal
      read GetMaxConnections write SetMaxConnections;
  end;


{ ****************** THttpApiWebSocketServer Over Windows http.sys Module }

type
  TSynThreadPoolHttpApiWebSocketServer = class;
  TSynWebSocketGuard = class;
  THttpApiWebSocketServer = class;
  THttpApiWebSocketServerProtocol = class;

  /// current state of a THttpApiWebSocketConnection
  TWebSocketState = (
    wsConnecting,
    wsOpen,
    wsClosing,
    wsClosedByClient,
    wsClosedByServer,
    wsClosedByGuard,
    wsClosedByShutdown);

  /// structure representing a single WebSocket connection
  {$ifdef USERECORDWITHMETHODS}
  THttpApiWebSocketConnection = record
  {$else}
  THttpApiWebSocketConnection = object
  {$endif USERECORDWITHMETHODS}
  private
    fOverlapped: TOverlapped;
    fState: TWebSocketState;
    fProtocol: THttpApiWebSocketServerProtocol;
    fOpaqueHTTPRequestId: HTTP_REQUEST_ID;
    fWSHandle: WEB_SOCKET_HANDLE;
    fLastActionContext: pointer;
    fLastReceiveTickCount: Int64;
    fPrivateData: pointer;
    fBuffer: RawByteString;
    fCloseStatus: WEB_SOCKET_CLOSE_STATUS;
    fIndex: integer;
    function ProcessActions(ActionQueue: cardinal): boolean;
    function ReadData(const WebsocketBufferData): integer;
    procedure WriteData(const WebsocketBufferData);
    procedure BeforeRead;
    procedure DoOnMessage(aBufferType: WEB_SOCKET_BUFFER_TYPE;
      aBuffer: pointer; aBufferSize: ULONG);
    procedure DoOnConnect;
    procedure DoOnDisconnect;
    procedure InternalSend(aBufferType: WEB_SOCKET_BUFFER_TYPE; WebsocketBufferData: pointer);
    procedure Ping;
    procedure Disconnect;
    procedure CheckIsActive;
    // call onAccept Method of protocol, and if protocol not accept connection or
    // can not be accepted from other reasons return false else return true
    function TryAcceptConnection(aProtocol: THttpApiWebSocketServerProtocol;
      Ctxt: THttpServerRequestAbstract; aNeedHeader: boolean): boolean;
  public
    /// Send data to client
    procedure Send(aBufferType: WEB_SOCKET_BUFFER_TYPE;
      aBuffer: pointer; aBufferSize: ULONG);
    /// Close connection
    procedure Close(aStatus: WEB_SOCKET_CLOSE_STATUS;
      aBuffer: pointer; aBufferSize: ULONG);
    /// Index of connection in protocol's connection list
    property Index: integer
      read fIndex;
    /// Protocol of connection
    property Protocol: THttpApiWebSocketServerProtocol
       read fProtocol;
    /// Custom user data
    property PrivateData: pointer
      read fPrivateData write fPrivateData;
    /// Access to the current state of this connection
    property State: TWebSocketState
      read fState;
  end;

  PHttpApiWebSocketConnection = ^THttpApiWebSocketConnection;

  THttpApiWebSocketConnectionVector =
    array[0..MaxInt div SizeOf(PHttpApiWebSocketConnection) - 1] of
    PHttpApiWebSocketConnection;

  PHttpApiWebSocketConnectionVector = ^THttpApiWebSocketConnectionVector;

  /// Event handler on THttpApiWebSocketServerProtocol Accepted connection
  TOnHttpApiWebSocketServerAcceptEvent = function(Ctxt: THttpServerRequest;
    var Conn: THttpApiWebSocketConnection): boolean of object;
  /// Event handler on THttpApiWebSocketServerProtocol Message received
  TOnHttpApiWebSocketServerMessageEvent = procedure(var Conn: THttpApiWebSocketConnection;
    aBufferType: WEB_SOCKET_BUFFER_TYPE; aBuffer: pointer; aBufferSize: ULONG) of object;
  /// Event handler on THttpApiWebSocketServerProtocol connection
  TOnHttpApiWebSocketServerConnectEvent = procedure(
    var Conn: THttpApiWebSocketConnection) of object;
  /// Event handler on THttpApiWebSocketServerProtocol disconnection
  TOnHttpApiWebSocketServerDisconnectEvent = procedure(var Conn: THttpApiWebSocketConnection;
    aStatus: WEB_SOCKET_CLOSE_STATUS; aBuffer: pointer; aBufferSize: ULONG) of object;

  /// Protocol Handler of websocket endpoints events
  // - maintains a list of all WebSockets clients for a given protocol
  THttpApiWebSocketServerProtocol = class
  private
    fName: RawUtf8;
    fManualFragmentManagement: boolean;
    fOnAccept: TOnHttpApiWebSocketServerAcceptEvent;
    fOnMessage: TOnHttpApiWebSocketServerMessageEvent;
    fOnFragment: TOnHttpApiWebSocketServerMessageEvent;
    fOnConnect: TOnHttpApiWebSocketServerConnectEvent;
    fOnDisconnect: TOnHttpApiWebSocketServerDisconnectEvent;
    fConnections: PHttpApiWebSocketConnectionVector;
    fConnectionsCapacity: integer;
    //Count of used connections. Some of them can be nil(if not used more)
    fConnectionsCount: integer;
    fFirstEmptyConnectionIndex: integer;
    fServer: THttpApiWebSocketServer;
    fSafe: TRTLCriticalSection;
    fPendingForClose: TSynList;
    fIndex: integer;
    function AddConnection(aConn: PHttpApiWebSocketConnection): integer;
    procedure RemoveConnection(index: integer);
    procedure doShutdown;
  public
    /// initialize the WebSockets process
    // - if aManualFragmentManagement is true, onMessage will appear only for whole
    // received messages, otherwise OnFragment handler must be passed (for video
    // broadcast, for example)
    constructor Create(const aName: RawUtf8; aManualFragmentManagement: boolean;
      aServer: THttpApiWebSocketServer;
      const aOnAccept: TOnHttpApiWebSocketServerAcceptEvent;
      const aOnMessage: TOnHttpApiWebSocketServerMessageEvent;
      const aOnConnect: TOnHttpApiWebSocketServerConnectEvent;
      const aOnDisconnect: TOnHttpApiWebSocketServerDisconnectEvent;
      const aOnFragment: TOnHttpApiWebSocketServerMessageEvent = nil);
    /// finalize the process
    destructor Destroy; override;
    /// text identifier
    property Name: RawUtf8
      read fName;
    /// identify the endpoint instance
    property Index: integer
      read fIndex;
    /// OnFragment event will be called for each fragment
    property ManualFragmentManagement: boolean
      read fManualFragmentManagement;
    /// event triggerred when a WebSockets client is initiated
    property OnAccept: TOnHttpApiWebSocketServerAcceptEvent
      read fOnAccept;
    /// event triggerred when a WebSockets message is received
    property OnMessage: TOnHttpApiWebSocketServerMessageEvent
      read fOnMessage;
    /// event triggerred when a WebSockets client is connected
    property OnConnect: TOnHttpApiWebSocketServerConnectEvent
      read fOnConnect;
    /// event triggerred when a WebSockets client is gracefully disconnected
    property OnDisconnect: TOnHttpApiWebSocketServerDisconnectEvent
      read fOnDisconnect;
    /// event triggerred when a non complete frame is received
    // - required if ManualFragmentManagement is true
    property OnFragment: TOnHttpApiWebSocketServerMessageEvent
      read fOnFragment;

    /// Send message to the WebSocket connection identified by its index
    function Send(index: integer; aBufferType: ULONG;
      aBuffer: pointer; aBufferSize: ULONG): boolean;
    /// Send message to all connections of this protocol
    function Broadcast(aBufferType: ULONG;
      aBuffer: pointer; aBufferSize: ULONG): boolean;
    /// Close WebSocket connection identified by its index
    function Close(index: integer; aStatus: WEB_SOCKET_CLOSE_STATUS;
      aBuffer: pointer; aBufferSize: ULONG): boolean;
  end;

  THttpApiWebSocketServerProtocolDynArray =
    array of THttpApiWebSocketServerProtocol;
  PHttpApiWebSocketServerProtocolDynArray =
    ^THttpApiWebSocketServerProtocolDynArray;

  /// HTTP & WebSocket server using fast http.sys kernel-mode server
  // - can be used like simple THttpApiServer
  // - when AddUrlWebSocket is called WebSocket support are added
  // in this case WebSocket will receiving the frames in asynchronous
  THttpApiWebSocketServer = class(THttpApiServer)
  private
    fThreadPoolServer: TSynThreadPoolHttpApiWebSocketServer;
    fGuard: TSynWebSocketGuard;
    fLastConnection: PHttpApiWebSocketConnection;
    fPingTimeout: integer;
    fRegisteredProtocols: PHttpApiWebSocketServerProtocolDynArray;
    fOnWSThreadStart: TOnNotifyThread;
    fOnWSThreadTerminate: TOnNotifyThread;
    fSendOverlaped: TOverlapped;
    fServiceOverlaped: TOverlapped;
    fOnServiceMessage: TThreadMethod;
    procedure SetOnWSThreadTerminate(const Value: TOnNotifyThread);
    function GetProtocol(index: integer): THttpApiWebSocketServerProtocol;
    function GetProtocolsCount: integer;
    procedure SetOnWSThreadStart(const Value: TOnNotifyThread);
  protected
    function UpgradeToWebSocket(Ctxt: THttpServerRequestAbstract): cardinal;
    procedure DoAfterResponse(Ctxt: THttpServerRequest; const Referer: RawUtf8;
      StatusCode: cardinal; Elapsed, Received, Sent: QWord); override;
    function GetSendResponseFlags(Ctxt: THttpServerRequest): integer; override;
    procedure DestroyMainThread; override;
  public
    /// initialize the HTTPAPI based Server with WebSocket support
    // - will raise an exception if http.sys or websocket.dll is not available
    // (e.g. before Windows 8) or if the request queue creation failed
    // - for aPingTimeout explanation see PingTimeout property documentation
    constructor Create(aSocketThreadsCount: integer = 1;
      aPingTimeout: integer = 0; const QueueName: SynUnicode = '';
      const aOnWSThreadStart: TOnNotifyThread = nil;
      const aOnWSThreadTerminate: TOnNotifyThread = nil;
      ProcessOptions: THttpServerOptions = []); reintroduce;
    /// create a WebSockets processing clone from the main thread
    // - do not use directly - is called during thread pool creation
    constructor CreateClone(From: THttpApiServer); override;
    /// prepare the process for a given THttpApiWebSocketServerProtocol
    procedure RegisterProtocol(const aName: RawUtf8; aManualFragmentManagement: boolean;
      const aOnAccept: TOnHttpApiWebSocketServerAcceptEvent;
      const aOnMessage: TOnHttpApiWebSocketServerMessageEvent;
      const aOnConnect: TOnHttpApiWebSocketServerConnectEvent;
      const aOnDisconnect: TOnHttpApiWebSocketServerDisconnectEvent;
      const aOnFragment: TOnHttpApiWebSocketServerMessageEvent = nil);
    /// register the URLs to Listen on using WebSocket
    // - aProtocols is an array of a recond with callbacks, server call during
    // WebSocket activity
    function AddUrlWebSocket(const aRoot, aPort: RawUtf8; Https: boolean = false;
      const aDomainName: RawUtf8 = '*'; aRegisterUri: boolean = false): integer;
    /// handle the HTTP request
    function Request(Ctxt: THttpServerRequestAbstract): cardinal; override;
    /// Ping timeout in seconds. 0 mean no ping.
    // - if connection not receive messages longer than this timeout
    // TSynWebSocketGuard will send ping frame
    // - if connection not receive any messages longer than double of
    // this timeout it will be closed
    property PingTimeout: integer
      read fPingTimeout;
    /// access to the associated endpoints
    property Protocols[index: integer]: THttpApiWebSocketServerProtocol
      read GetProtocol;
    /// access to the associated endpoints count
    property ProtocolsCount: integer
      read GetProtocolsCount;
    /// event called when the processing thread starts
    property OnWSThreadStart: TOnNotifyThread
      read FOnWSThreadStart write SetOnWSThreadStart;
    /// event called when the processing thread termintes
    property OnWSThreadTerminate: TOnNotifyThread
      read FOnWSThreadTerminate write SetOnWSThreadTerminate;
    /// send a "service" message to a WebSocketServer to wake up a WebSocket thread
    // - can be called from any thread
    // - when a webSocket thread receives such a message it will call onServiceMessage
    // in the thread context
    procedure SendServiceMessage;
    /// event called when a service message is raised
    property OnServiceMessage: TThreadMethod
      read fOnServiceMessage write fOnServiceMessage;
  end;

  /// a Thread Pool, used for fast handling of WebSocket requests
  TSynThreadPoolHttpApiWebSocketServer = class(TSynThreadPool)
  protected
    fServer: THttpApiWebSocketServer;
    procedure OnThreadStart(Sender: TThread);
    procedure OnThreadTerminate(Sender: TThread);
    function NeedStopOnIOError: boolean; override;
    // aContext is a PHttpApiWebSocketConnection, or fServer.fServiceOverlaped
    // (SendServiceMessage) or fServer.fSendOverlaped (WriteData)
    procedure Task(aCaller: TSynThreadPoolWorkThread;
      aContext: pointer); override;
  public
    /// initialize the thread pool
    constructor Create(Server: THttpApiWebSocketServer;
      NumberOfThreads: integer = 1); reintroduce;
  end;

  /// Thread for closing deprecated WebSocket connections
  // - i.e. which have not responsed after PingTimeout interval
  TSynWebSocketGuard = class(TThread)
  protected
    fServer: THttpApiWebSocketServer;
    fSmallWait, fWaitCount: integer;
    procedure Execute; override;
  public
    /// initialize the thread
    constructor Create(Server: THttpApiWebSocketServer); reintroduce;
  end;

{$endif USEWININET}


implementation


{ ******************** Abstract UDP Server }

{ TUdpServerThread }

procedure TUdpServerThread.OnIdle(tix64: Int64);
begin
  // do nothing by default
end;

constructor TUdpServerThread.Create(LogClass: TSynLogClass;
  const BindAddress, BindPort, ProcessName: RawUtf8; TimeoutMS: integer);
var
  ident: RawUtf8;
  res: TNetResult;
begin
  GetMem(fFrame, SizeOf(fFrame^));
  ident := ProcessName;
  if ident = '' then
    FormatUtf8('udp%srv', [BindPort], ident);
   LogClass.Add.Log(sllTrace, 'Create: bind %:% for input requests on %',
     [BindAddress, BindPort, ident], self);
  res := NewSocket(BindAddress, BindPort, nlUdp, {bind=}true,
    TimeoutMS, TimeoutMS, TimeoutMS, 10, fSock, @fSockAddr);
  if res <> nrOk then
    // on binding error, raise exception before the thread is actually created
    raise EUdpServer.Create('%s.Create binding error on %s:%s',
      [ClassNameShort(self)^, BindAddress, BindPort], res);
  AfterBind;
  inherited Create({suspended=}false, LogClass, ident);
end;

destructor TUdpServerThread.Destroy;
var
  sock: TNetSocket;
begin
  fLogClass.Add.Log(sllDebug, 'Destroy: ending %', [fProcessName], self);
  // try to release fSock.WaitFor(1000) in DoExecute
  Terminate;
  if fProcessing and
     (fSock <> nil) then
  {$ifdef OSPOSIX} // a broadcast address won't reach DoExecute
  if (fSockAddr.IP4 and $ff000000) = $ff000000 then // check x.x.x.255
    fSock.ShutdownAndClose({rdwr=}true) // will release acept() ASAP
  else
  {$endif OSPOSIX}
  begin
    sock := fSockAddr.NewSocket(nlUdp);
    if sock <> nil then
    begin
      fLogClass.Add.Log(sllTrace, 'Destroy: send final packet', self);
      sock.SetSendTimeout(10);
      sock.SendTo(pointer(UDP_SHUTDOWN), length(UDP_SHUTDOWN), fSockAddr);
      sock.ShutdownAndClose(false);
    end;
  end;
  // finalize this thread process
  TerminateAndWaitFinished;
  inherited Destroy;
  if fSock <> nil then
    fSock.ShutdownAndClose({rdwr=}true);
  FreeMem(fFrame);
end;

function TUdpServerThread.GetIPWithPort: RawUtf8;
begin
  result := fSockAddr.IPWithPort;
end;

procedure TUdpServerThread.AfterBind;
begin
  // do nothing by default
end;

procedure TUdpServerThread.DoExecute;
var
  len: integer;
  tix64: Int64;
  tix, lasttix: cardinal;
  remote: TNetAddr;
  res: TNetResult;
begin
  fProcessing := true;
  lasttix := 0;
  // main server process loop
  try
    if fSock = nil then // paranoid check
      raise EUdpServer.CreateFmt('%s.Execute: Bind failed', [ClassNameShort(self)^]);
    while not Terminated do
    begin
      if fSock.WaitFor(1000, [neRead, neError]) <> [] then
      begin
        if Terminated then
        begin
          fLogClass.Add.Log(sllDebug, 'DoExecute: Terminated', self);
          break;
        end;
        res := fSock.RecvPending(len);
        if (res = nrOk) and
           (len >= 4) then
        begin
          PInteger(fFrame)^ := 0;
          len := fSock.RecvFrom(fFrame, SizeOf(fFrame^), remote);
          if Terminated then
            break;
          if (len >= 0) and // -1=error, 0=shutdown
             (CompareBuf(UDP_SHUTDOWN, fFrame, len) <> 0) then // paranoid
          begin
            inc(fReceived);
            OnFrameReceived(len, remote);
          end;
        end
        else if res <> nrRetry then
          SleepHiRes(100); // don't loop with 100% cpu on failure
      end;
      if Terminated then
        break;
      tix64 := mormot.core.os.GetTickCount64;
      tix := tix64 shr 9; // div 512
      if tix <> lasttix then
      begin
        lasttix := tix;
        OnIdle(tix64); // called every 512 ms at most
      end;
    end;
    OnShutdown; // should close all connections
  except
    on E: Exception do
      // any exception would break and release the thread
      FormatUtf8('% [%]', [E, E.Message], fExecuteMessage);
  end;
  fProcessing := false;
end;


{ ******************** Custom URI Routing using an efficient Radix Tree }

function UriMethod(const Text: RawUtf8; out Method: TUriRouterMethod): boolean;
begin
  result := false;
  if Text = '' then
    exit;
  case PCardinal(Text)^ of // case-sensitive test in occurrence order
    ord('G') + ord('E') shl 8 + ord('T') shl 16:
      Method := urmGet;
    ord('P') + ord('O') shl 8 + ord('S') shl 16 + ord('T') shl 24:
      Method := urmPost;
    ord('P') + ord('U') shl 8 + ord('T') shl 16:
      Method := urmPut;
    ord('P') + ord('A') shl 8 + ord('T') shl 16 + ord('C') shl 24:
      Method := urmPatch;
    ord('H') + ord('E') shl 8 + ord('A') shl 16 + ord('D') shl 24:
      Method := urmHead;
    ord('D') + ord('E') shl 8 + ord('L') shl 16 + ord('E') shl 24:
      Method := urmDelete;
    ord('O') + ord('P') shl 8 + ord('T') shl 16 + ord('I') shl 24:
      Method := urmOptions;
  else
    exit;
  end;
  result := true;
end;

function IsValidUriRoute(p: PUtf8Char): boolean;
begin
  result := false;
  if p = nil then
    exit;
  repeat
    if p^ = '<' then // parse <param> or <path:param> place-holders
    begin
      inc(p);
      while p^ <> '>' do
        if p^ = #0 then
          exit
        else
          inc(p);
    end
    else if not (p^ in ['/', '_', '-', '.', '$', '0'..'9', 'a'..'z', 'A'..'Z']) then
      exit; // not a valid plain URI character
    inc(p);
  until p^ = #0;
  result := true;
end;


{ TUriTreeNode }

function TUriTreeNode.Split(const Text: RawUtf8): TRadixTreeNode;
begin
  result := inherited Split(Text);
  TUriTreeNode(result).Data := Data;
  Finalize(Data);
  FillCharFast(Data, SizeOf(Data), 0);
end;

function TUriTreeNode.LookupParam(Ctxt: TObject; Pos: PUtf8Char; Len: integer): boolean;
var
  req: THttpServerRequest absolute Ctxt;
  n: PtrInt;
  v: PIntegerArray;
begin
  result := false;
  if Len < 0 then // Pos^ = '?par=val&par=val&...'
  begin
    include(req.fInternalFlags, ifUrlParamPosSet);
    req.fUrlParamPos := Pos; // for faster req.UrlParam()
    exit;
  end;
  req.fRouteName := pointer(Names); // fast assignment as pointer reference
  n := length(Names) * 2; // length(Names[]) = current parameter index
  if length(req.fRouteValuePosLen) < n then
    SetLength(req.fRouteValuePosLen, n + 24); // alloc once by 12 params
  v := @req.fRouteValuePosLen[n - 2];
  n := Pos - pointer(req.Url);
  if PtrUInt(n) > PtrUInt(length(req.Url)) then
    exit; // paranoid check to avoid any overflow
  v[0] := n;   // value position (0-based) in Ctxt.Url
  v[1] := Len; // value length in Ctxt.Url
  result := true;
end;

procedure TUriTreeNode.RewriteUri(Ctxt: THttpServerRequestAbstract);
var
  n: TDALen;
  len: integer;
  t, v: PIntegerArray;
  p: PUtf8Char;
  new: pointer; // fast temporary RawUtf8
begin
  // compute length of the new URI with injected values
  t := pointer(Data.ToUriPosLen); // [pos1,len1,valndx1,...] trio rules
  n := PDALen(PAnsiChar(t) - _DALEN)^ + _DAOFF;
  v := pointer(THttpServerRequest(Ctxt).fRouteValuePosLen); // [pos,len] pairs
  if v = nil then
     exit; // paranoid
  len := Data.ToUriStaticLen;
  repeat
    if t[2] >= 0 then            // t[2]=valndx in v=fRouteValuePosLen[]
      inc(len, v[t[2] * 2 + 1]); // add value length
    t := @t[3];
    dec(n, 3)
  until n = 0;
  // compute the new URI with injected values
  new := FastNewString(len, CP_UTF8);
  t := pointer(Data.ToUriPosLen);
  n := PDALen(PAnsiChar(t) - _DALEN)^ + _DAOFF;
  p := new; // write new URI
  repeat
    if t[1] <> 0 then    // t[1]=len
    begin
      MoveFast(PByteArray(Data.ToUri)[t[0]], p^, t[1]); // static
      inc(p, t[1]);
    end;
    if t[2] >= 0 then    // t[2]=valndx in fRouteValuePosLen[]
    begin
      v := @THttpServerRequest(Ctxt).fRouteValuePosLen[t[2] * 2];
      MoveFast(PByteArray(Ctxt.Url)[v[0]], p^, v[1]); // value [pos,len] pair
      inc(p, v[1]);
    end;
    t := @t[3];
    dec(n, 3)
  until n = 0;
  FastAssignNew(THttpServerRequest(Ctxt).fUrl, new); // replace
  //if p - new <> len then raise EUriRouter.Create('??');
end;


{ TUriTree }

function TUriTree.Root: TUriTreeNode;
begin
  result := fRoot as TUriTreeNode;
end;


{ TUriRouter }

destructor TUriRouter.Destroy;
var
  m: TUriRouterMethod;
begin
  inherited Destroy;
  for m := low(fTree) to high(fTree) do
    fTree[m].Free;
end;

procedure TUriRouter.Clear(aMethods: TUriRouterMethods);
var
  m: TUriRouterMethod;
begin
  if self = nil then
    exit; // avoid unexpected GPF
  fSafe.WriteLock;
  try
    FillCharFast(fEntries, SizeOf(fEntries), 0);
    for m := low(fTree) to high(fTree) do
      if m in aMethods then
        FreeAndNil(fTree[m]);
  finally
    fSafe.WriteUnLock;
  end;
end;

procedure TUriRouter.Setup(aFrom: TUriRouterMethod; const aFromUri: RawUtf8;
  aTo: TUriRouterMethod; const aToUri: RawUtf8;
  const aExecute: TOnHttpServerRequest; aExecuteOpaque: pointer);
var
  n: TUriTreeNode;
  u: PUtf8Char;
  fromU, toU, item: RawUtf8;
  names: TRawUtf8DynArray;
  pos: PtrInt;
begin
  if self = nil then
    exit; // avoid unexpected GPF
  fromU := StringReplaceAll(aFromUri, '*', '<path:path>');
  toU := StringReplaceAll(aToUri, '*', '<path:path>');
  if not IsValidUriRoute(pointer(fromU)) then
    EUriRouter.RaiseUtf8('Invalid char in %.Setup(''%'')',
      [self, aFromUri]);
  fSafe.WriteLock;
  try
    if fTree[aFrom] = nil then
      fTree[aFrom] := TUriTree.Create(fTreeNodeClass, fTreeOptions);
    n := fTree[aFrom].Setup(fromU, names) as TUriTreeNode;
    if n = nil then
      exit;
    // the leaf should have the Rewrite/Run information to process on match
    if n.Data.ToUri <> '' then
      if toU = n.Data.ToUri then
        exit // same redirection: do nothing
      else
        EUriRouter.RaiseUtf8('%.Setup(''%''): already redirect to %',
          [self, aFromUri, n.Data.ToUri]);
    if Assigned(n.Data.Execute) then
      if CompareMem(@n.Data.Execute, @aExecute, SizeOf(TMethod)) then
        exit // same callback: do nothing
      else
        EUriRouter.RaiseUtf8('%.Setup(''%''): already registered',
          [self, aFromUri]);
    if Assigned(aExecute) then
    begin
      // this URI should redirect to a TOnHttpServerRequest callback
      n.Data.Execute := aExecute;
      n.Data.ExecuteOpaque := aExecuteOpaque;
    end
    else
    begin
      n.Data.ToUriMethod := aTo;
      n.Data.ToUri := toU;
      n.Data.ToUriPosLen := nil; // store [pos1,len1,valndx1,...] trios
      n.Data.ToUriStaticLen := 0;
      n.Data.ToUriErrorStatus := Utf8ToInteger(toU, 200, 599, 0);
      if n.Data.ToUriErrorStatus = 0 then // a true URI, not an HTTP error code
      begin
        // pre-compute the rewritten URI into Data.ToUriPosLen[]
        u := pointer(toU);
        if u = nil then
          EUriRouter.RaiseUtf8('No ToUri in %.Setup(''%'')',
            [self, aFromUri]);
        if PosExChar('<', toU) <> 0 then // n.Data.ToUriPosLen=nil to use ToUri
          repeat
            pos := u - pointer(toU);
            GetNextItem(u, '<', item); // static
            AddInteger(n.Data.ToUriPosLen, pos);          // position
            AddInteger(n.Data.ToUriPosLen, length(item)); // length (may be 0)
            inc(n.Data.ToUriStaticLen, length(item));
            if (u = nil) or
               (u^ = #0) then
              pos := -1
            else
            begin
              GetNextItem(u, '>', item); // <name>
              pos := PosExChar(':', item);
              if pos <> 0 then
                system.delete(item, 1, pos);
              if item = '' then
                EUriRouter.RaiseUtf8('Void <> in %.Setup(''%'')',
                  [self, aToUri]);
              pos := FindRawUtf8(names, item);
              if pos < 0 then
                EUriRouter.RaiseUtf8('Unknown <%> in %.Setup(''%'')',
                  [item, self, aToUri]);
            end;
            AddInteger(n.Data.ToUriPosLen, pos);  // value index in Names[]
          until (u = nil) or
                (u^ = #0);
      end;
    end;
    inc(fEntries[aFrom]);
  finally
    fSafe.WriteUnLock;
  end;
end;

constructor TUriRouter.Create(aNodeClass: TRadixTreeNodeClass;
  aOptions: TRadixTreeOptions);
begin
  if aNodeClass = nil then
    EUriRouter.RaiseUtf8('%.Create with aNodeClass=nil', [self]);
  fTreeNodeClass := aNodeClass;
  fTreeOptions := aOptions;
  inherited Create;
end;

procedure TUriRouter.Rewrite(aFrom: TUriRouterMethod; const aFromUri: RawUtf8;
  aTo: TUriRouterMethod; const aToUri: RawUtf8);
begin
  Setup(aFrom, aFromUri, aTo, aToUri, nil, nil);
end;

procedure TUriRouter.Run(aFrom: TUriRouterMethods; const aFromUri: RawUtf8;
  const aExecute: TOnHttpServerRequest; aExecuteOpaque: pointer);
var
  m: TUriRouterMethod;
begin
  for m := low(fTree) to high(fTree) do
    if m in aFrom then
      Setup(m, aFromUri, m, '', aExecute, aExecuteOpaque);
end;

procedure TUriRouter.Get(const aFrom, aTo: RawUtf8; aToMethod: TUriRouterMethod);
begin
  Rewrite(urmGet, aFrom, aToMethod, aTo);
end;

procedure TUriRouter.Post(const aFrom, aTo: RawUtf8; aToMethod: TUriRouterMethod);
begin
  Rewrite(urmPost, aFrom, aToMethod, aTo);
end;

procedure TUriRouter.Put(const aFrom, aTo: RawUtf8; aToMethod: TUriRouterMethod);
begin
  Rewrite(urmPut, aFrom, aToMethod, aTo);
end;

procedure TUriRouter.Patch(const aFrom, aTo: RawUtf8; aToMethod: TUriRouterMethod);
begin
  Rewrite(urmPatch, aFrom, aToMethod, aTo);
end;

procedure TUriRouter.Delete(const aFrom, aTo: RawUtf8; aToMethod: TUriRouterMethod);
begin
  Rewrite(urmDelete, aFrom, aToMethod, aTo);
end;

procedure TUriRouter.Options(const aFrom, aTo: RawUtf8;
  aToMethod: TUriRouterMethod);
begin
  Rewrite(urmOptions, aFrom, aToMethod, aTo);
end;

procedure TUriRouter.Head(const aFrom, aTo: RawUtf8; aToMethod: TUriRouterMethod);
begin
  Rewrite(urmHead, aFrom, aToMethod, aTo);
end;

procedure TUriRouter.Get(const aUri: RawUtf8;
  const aExecute: TOnHttpServerRequest; aExecuteOpaque: pointer);
begin
  Run([urmGet], aUri, aExecute, aExecuteOpaque);
end;

procedure TUriRouter.Post(const aUri: RawUtf8;
  const aExecute: TOnHttpServerRequest; aExecuteOpaque: pointer);
begin
  Run([urmPost], aUri, aExecute, aExecuteOpaque);
end;

procedure TUriRouter.Put(const aUri: RawUtf8;
  const aExecute: TOnHttpServerRequest; aExecuteOpaque: pointer);
begin
  Run([urmPut], aUri, aExecute, aExecuteOpaque);
end;

procedure TUriRouter.Patch(const aUri: RawUtf8;
  const aExecute: TOnHttpServerRequest; aExecuteOpaque: pointer);
begin
  Run([urmPatch], aUri, aExecute, aExecuteOpaque);
end;

procedure TUriRouter.Delete(const aUri: RawUtf8;
  const aExecute: TOnHttpServerRequest; aExecuteOpaque: pointer);
begin
  Run([urmDelete], aUri, aExecute, aExecuteOpaque);
end;

procedure TUriRouter.Options(const aUri: RawUtf8;
  const aExecute: TOnHttpServerRequest; aExecuteOpaque: pointer);
begin
  Run([urmOptions], aUri, aExecute, aExecuteOpaque);
end;

procedure TUriRouter.Head(const aUri: RawUtf8;
  const aExecute: TOnHttpServerRequest; aExecuteOpaque: pointer);
begin
  Run([urmHead], aUri, aExecute, aExecuteOpaque);
end;

procedure TUriRouter.RunMethods(RouterMethods: TUriRouterMethods;
  Instance: TObject; const Prefix: RawUtf8);
var
  met: TPublishedMethodInfoDynArray;
  m: PtrInt;
begin
  if (self <> nil) and
     (Instance <> nil) and
     (RouterMethods <> []) then
    for m := 0 to GetPublishedMethods(Instance, met) - 1 do
      Run(RouterMethods, Prefix + StringReplaceChars(met[m].Name, '_', '-'),
        TOnHttpServerRequest(met[m].Method));
end;

function TUriRouter.Process(Ctxt: THttpServerRequestAbstract): integer;
var
  m: TUriRouterMethod;
  t: TUriTree;
  found: TUriTreeNode;
begin
  result := 0; // nothing to process
  if (self = nil) or
     (Ctxt = nil) or
     (Ctxt.Url = '') or
     not UriMethod(Ctxt.Method, m) then
    exit;
  THttpServerRequest(Ctxt).fRouteName := nil; // paranoid: if called w/o Prepare
  THttpServerRequest(Ctxt).fRouteNode := nil;
  t := fTree[m];
  if t = nil then
    exit; // this method has no registration yet
  fSafe.ReadLock;
  {$ifdef HASFASTTRYFINALLY}
  try
  {$else}
  begin
  {$endif HASFASTTRYFINALLY}
    // fast recursive parsing - may return nil, but never raises exception
    found := pointer(TUriTreeNode(t.fRoot).Lookup(pointer(Ctxt.Url), Ctxt));
  {$ifdef HASFASTTRYFINALLY}
  finally
  {$endif HASFASTTRYFINALLY}
    fSafe.ReadUnLock;
  end;
  if found <> nil then
    // there is something to react on
    if Assigned(found.Data.Execute) then
    begin
      // request is implemented via a method
      THttpServerRequest(Ctxt).fRouteNode := found;
      result := found.Data.Execute(Ctxt);
    end
    else if found.Data.ToUri <> '' then
    begin
      // request is not implemented here, but the Url should be rewritten
      if m <> found.Data.ToUriMethod then
        Ctxt.Method := URIROUTERMETHOD[found.Data.ToUriMethod];
      if found.Data.ToUriErrorStatus <> 0 then
        result := found.Data.ToUriErrorStatus // redirect to an error code
      else if found.Data.ToUriPosLen = nil then
        Ctxt.Url := found.Data.ToUri    // only static -> just replace URI
      else
        found.RewriteUri(Ctxt);         // compute new URI with injected values
    end;
end;

function TUriRouter.Lookup(const aUri, aUriMethod: RawUtf8): TUriTreeNode;
var
  m: TUriRouterMethod;
  t: TUriTree;
begin
  result := nil;
  if (self = nil) or
     (aUri = '') or
     not UriMethod(aUriMethod, m) then
    exit;
  t := fTree[m];
  if t = nil then
    exit; // this method has no registration yet
  fSafe.ReadLock;
  {$ifdef HASFASTTRYFINALLY}
  try
  {$else}
  begin
  {$endif HASFASTTRYFINALLY}
    result := pointer(TUriTreeNode(t.fRoot).Lookup(pointer(aUri), nil));
  {$ifdef HASFASTTRYFINALLY}
  finally
  {$endif HASFASTTRYFINALLY}
    fSafe.ReadUnLock;
  end;
end;


{ ******************** Shared Server-Side HTTP Process }

{ THttpServerRequest }

constructor THttpServerRequest.Create(aServer: THttpServerGeneric;
  aConnectionID: THttpServerConnectionID; aConnectionThread: TSynThread;
  aConnectionAsyncHandle: TConnectionAsyncHandle;
  aConnectionFlags: THttpServerRequestFlags;
  aConnectionOpaque: PHttpServerConnectionOpaque);
begin
  inherited Create;
  fServer := aServer;
  fConnectionID := aConnectionID;
  fConnectionThread := aConnectionThread;
  fConnectionAsyncHandle := aConnectionAsyncHandle;
  fConnectionFlags := aConnectionFlags;
  fConnectionOpaque := aConnectionOpaque;
end;

procedure THttpServerRequest.Recycle(aConnectionID: THttpServerConnectionID;
  aConnectionThread: TSynThread; aConnectionAsyncHandle: TConnectionAsyncHandle;
  aConnectionFlags: THttpServerRequestFlags;
  aConnectionOpaque: PHttpServerConnectionOpaque);
begin
  fConnectionID := aConnectionID;
  fConnectionAsyncHandle := aConnectionAsyncHandle;
  fConnectionThread := aConnectionThread;
  fConnectionFlags := aConnectionFlags;
  fConnectionOpaque := aConnectionOpaque;
  // reset fields as Create() does
  FastAssignNew(fHost);
  FastAssignNew(fAuthBearer);
  FastAssignNew(fUserAgent);
  fRespStatus := 0;
  fOutContent := '';
  FastAssignNew(fOutContentType);
  FastAssignNew(fOutCustomHeaders);
  fAuthenticationStatus := hraNone;
  fInternalFlags := [];
  FastAssignNew(fAuthenticatedUser);
  fErrorMessage := '';
  fUrlParamPos := nil;
  fRouteNode := nil;
  fRouteName := nil; // no fRouteValuePosLen := nil (to reuse allocated array)
  // Prepare() will set the other fields
end;

destructor THttpServerRequest.Destroy;
begin
  fTempWriter.Free;
  // inherited Destroy; is void
end;

const
  _CMD_200: array[boolean, boolean] of string[31] = (
   ('HTTP/1.1 200 OK'#13#10,
    'HTTP/1.0 200 OK'#13#10),
   ('HTTP/1.1 206 Partial Content'#13#10,
    'HTTP/1.0 206 Partial Content'#13#10));
  _CMD_XXX: array[boolean] of string[15] = (
    'HTTP/1.1 ',
    'HTTP/1.0 ');

function THttpServerRequest.SetupResponse(var Context: THttpRequestContext;
  CompressGz, MaxSizeAtOnce: integer): PRawByteStringBuffer;

  procedure ProcessStaticFile;
  var
    fn: TFileName;
    progsizeHeader: RawUtf8; // for rfProgressiveStatic mode
    h: THandle;
  begin
    ExtractOutContentType;
    Utf8ToFileName(OutContent, fn);
    OutContent := '';
    ExtractHeader(fOutCustomHeaders, STATICFILE_PROGSIZE, progsizeHeader);
    SetInt64(pointer(progsizeHeader), Context.ContentLength);
    if Context.ContentLength <> 0 then
      // STATICFILE_PROGSIZE: file is not fully available: wait for sending
      if ((not (rfWantRange in Context.ResponseFlags)) or
          Context.ValidateRange) then
      begin
        h := FileOpen(fn, fmOpenReadShared);
        if ValidHandle(h) then
        begin
          Context.ContentStream := TFileStreamEx.CreateFromHandle(h, fn);
          Context.ResponseFlags := Context.ResponseFlags +
            [rfAcceptRange, rfContentStreamNeedFree, rfProgressiveStatic];
          FileInfoByHandle(h, nil, nil, @Context.ContentLastModified, nil);
        end
        else
          fRespStatus := HTTP_NOTFOUND
      end
      else
        fRespStatus := HTTP_RANGENOTSATISFIABLE
    else if (not Assigned(fServer.OnSendFile)) or
            (not fServer.OnSendFile(self, fn)) then
    begin
      // regular file sending by chunks
      fRespStatus := Context.ContentFromFile(fn, CompressGz);
      if fRespStatus = HTTP_SUCCESS then
        OutContent := Context.Content; // small static file content
    end;
    if not StatusCodeIsSuccess(fRespStatus) then
      fErrorMessage := 'Error getting file'; // detected by ProcessErrorMessage
  end;

  procedure ProcessErrorMessage;
  begin
    HtmlEscapeString(fErrorMessage, fOutContentType, hfAnyWhere);
    FormatUtf8(
      '<!DOCTYPE html><html><body style="font-family:verdana">' +
      '<h1>% Server Error %</h1><hr>' +
      '<p>HTTP %</p><p>%</p><small>%</small></body></html>',
      [fServer.ServerName, fRespStatus, StatusCodeToShort(fRespStatus),
       fOutContentType, XPOWEREDVALUE],
      RawUtf8(fOutContent));
    fOutCustomHeaders := '';
    fOutContentType := 'text/html; charset=utf-8'; // create message to display
  end;

var
  P, PEnd: PUtf8Char;
  len: PtrInt;
  status: PtrUInt;
  h: PRawByteStringBuffer;
  // note: caller should have set hfConnectionClose in Context.HeaderFlags
begin
  // process content
  Context.ContentLength := 0; // needed by ProcessStaticFile
  Context.ContentLastModified := 0;
  if (fOutContentType <> '') and
     (fOutContentType[1] = '!') then
    if fOutContentType = NORESPONSE_CONTENT_TYPE then
      fOutContentType := '' // true HTTP always expects a response
    else if (fOutContent <> '') and
            (fOutContentType = STATICFILE_CONTENT_TYPE) then
      ProcessStaticFile;
  if fErrorMessage <> '' then
    ProcessErrorMessage;
  // append Command
  h := @Context.Head;
  h^.Reset; // reuse 2KB header buffer
  if fRespStatus = HTTP_SUCCESS then // optimistic approach
    h^.AppendShort(_CMD_200[
      rfWantRange in Context.ResponseFlags, // HTTP_PARTIALCONTENT=206 support
      rfHttp10 in Context.ResponseFlags])   // HTTP/1.0 support
  else
  begin // other cases
    h^.AppendShort(_CMD_XXX[rfHttp10 in Context.ResponseFlags]);
    status := fRespStatus;
    if status > 999 then
      status := 999; // avoid SmallUInt32Utf8[] overflow
    h^.Append(SmallUInt32Utf8[status]);
    h^.Append(' ');
    h^.Append(StatusCodeToText(fRespStatus)^);
    h^.AppendCRLF;
  end;
  // append (and sanitize CRLF) custom headers from Request() method
  P := pointer(OutCustomHeaders);
  if P <> nil then
  begin
    PEnd := P + length(OutCustomHeaders);
    repeat
      len := BufferLineLength(P, PEnd); // use fast SSE2 assembly on x86-64 CPU
      if len > 0 then // no void line (means headers ending)
      begin
        if (PCardinal(P)^ or $20202020 =
             ord('c') + ord('o') shl 8 + ord('n') shl 16 + ord('t') shl 24) and
           (PCardinal(P + 4)^ or $20202020 =
             ord('e') + ord('n') shl 8 + ord('t') shl 16 + ord('-') shl 24) and
           (PCardinal(P + 8)^ or $20202020 =
             ord('e') + ord('n') shl 8 + ord('c') shl 16 + ord('o') shl 24) and
           (PCardinal(P + 12)^ or $20202020 =
             ord('d') + ord('i') shl 8 + ord('n') shl 16 + ord('g') shl 24) and
           (P[16] = ':') then
          // custom CONTENT-ENCODING: disable any late compression
          integer(Context.CompressAcceptHeader) := 0;
        h^.Append(P, len);
        h^.AppendCRLF; // normalize CR/LF endings
        inc(P, len);
      end;
      while P^ in [#10, #13] do
        inc(P);
    until P^ = #0;
  end;
  if Context.ResponseHeaders <> '' then // e.g. 'WWW-Authenticate: #####'#13#10
    h^.Append(Context.ResponseHeaders);
  // generic headers
  h^.Append(fServer.fRequestHeaders); // Server: and X-Powered-By:
  if hsoIncludeDateHeader in fServer.Options then
    fServer.AppendHttpDate(h^);
  Context.Content := fOutContent;
  Context.ContentType := fOutContentType;
  fOutContent := ''; // dec RefCnt to release body memory ASAP
  result := Context.CompressContentAndFinalizeHead(MaxSizeAtOnce); // set State
  // now TAsyncConnectionsSockets.Write(result) should be called
end;

procedure THttpServerRequest.SetErrorMessage(const Fmt: RawUtf8;
  const Args: array of const);
begin
  FormatString(Fmt, Args, fErrorMessage);
end;

function THttpServerRequest.TempJsonWriter(
  var temp: TTextWriterStackBuffer): TJsonWriter;
begin
  if fTempWriter = nil then
    fTempWriter := TJsonWriter.CreateOwnedStream(temp, {noshared=}true)
  else
    fTempWriter.CancelAllWith(temp);
  result := fTempWriter;
end;

function THttpServerRequest.SetOutJson(Value: pointer; TypeInfo: PRttiInfo): cardinal;
var
  temp: TTextWriterStackBuffer;
begin
  TempJsonWriter(temp).AddTypedJson(Value, TypeInfo, []);
  fTempWriter.SetText(RawUtf8(fOutContent));
  fOutContentType := JSON_CONTENT_TYPE_VAR;
  result := HTTP_SUCCESS;
end;

function THttpServerRequest.SetOutJson(Value: TObject): cardinal;
var
  temp: TTextWriterStackBuffer;
begin
  TempJsonWriter(temp).WriteObject(Value, []);
  fTempWriter.SetText(RawUtf8(fOutContent));
  fOutContentType := JSON_CONTENT_TYPE_VAR;
  result := HTTP_SUCCESS;
end;

function THttpServerRequest.RouteOpaque: pointer;
begin
  result := fRouteNode;
  if result <> nil then
    result := TUriTreeNode(result).Data.ExecuteOpaque;
end;

function THttpServerRequest.AsyncHandle: TConnectionAsyncHandle;
begin
  result := fConnectionAsyncHandle;
  if result = 0 then
    EHttpServer.RaiseUtf8('% has no async response support', [fServer]);
end;

{$ifdef USEWININET}

function THttpServerRequest.GetFullUrl: SynUnicode;
begin
  if fHttpApiRequest = nil then
    result := ''
  else
    // fHttpApiRequest^.CookedUrl.FullUrlLength is in bytes -> use ending #0
    result := fHttpApiRequest^.CookedUrl.pFullUrl;
end;

{$endif USEWININET}


{ THttpServerGeneric }

constructor THttpServerGeneric.Create(const OnStart, OnStop: TOnNotifyThread;
  const ProcessName: RawUtf8; ProcessOptions: THttpServerOptions);
begin
  fOptions := ProcessOptions; // should be set before SetServerName
  SetServerName('mORMot2 (' + OS_TEXT + ')');
  if hsoEnableLogging in fOptions then
  begin
    if fLogger = nil then // <> nil from THttpApiServer.CreateClone
    begin
      fLogger := THttpLogger.Create;
      fLogger.Parse(LOGFORMAT_COMBINED); // default nginx-like format
    end;
    fOnAfterResponse := fLogger.Append;   // redirect requests to the logger
  end;
  if fOptions * [hsoTelemetryCsv, hsoTelemetryJson] <> [] then
  begin
    if fAnalyzer = nil then // <> nil from THttpApiServer.CreateClone
      fAnalyzer := THttpAnalyzer.Create; // no suspend file involved
    fAnalyzer.OnContinue := fLogger;
    fOnAfterResponse := fAnalyzer.Append;
    if hsoTelemetryCsv in fOptions then
      THttpAnalyzerPersistCsv.CreateOwned(fAnalyzer);
    if hsoTelemetryJson in fOptions then
      THttpAnalyzerPersistJson.CreateOwned(fAnalyzer);
  end;
  inherited Create(hsoCreateSuspended in fOptions, OnStart, OnStop, ProcessName);
end;

destructor THttpServerGeneric.Destroy;
begin
  inherited Destroy;
  FreeAndNil(fRoute);
  FreeAndNil(fAnalyzer);
  FreeAndNil(fLogger);
end;

function THttpServerGeneric.Route: TUriRouter;
begin
  result := nil; // avoid GPF
  if self = nil then
    exit;
  result := fRoute;
  if result <> nil then
    exit;
  GlobalLock; // paranoid thread-safety
  try
    if fRoute = nil then
    begin
      if fRouterClass = nil then
        fRouterClass := TUriTreeNode;
      fRoute := TUriRouter.Create(fRouterClass);
    end;
  finally
    GlobalUnLock;
  end;
  result := fRoute;
end;

function THttpServerGeneric.ReplaceRoute(another: TUriRouter): TUriRouter;
begin
  result := nil;
  if self = nil then
    exit;
  if fFavIconRouted then
    another.Get('/favicon.ico', GetFavIcon); // let SetFavIcon() continue
  GlobalLock; // paranoid thread-safety
  try
    result := fRoute;
    if result <> nil then
      result.Safe.WriteLock;
    fRoute := another;
    if result <> nil then
      result.Safe.WriteUnLock;
  finally
    GlobalUnLock;
  end;
end;

procedure THttpServerGeneric.SetFavIcon(const FavIconContent: RawByteString);
begin
  if FavIconContent = 'default' then
    fFavIcon := FavIconBinary
  else
    fFavIcon := FavIconContent;
  if fFavIconRouted then
    exit; // need to register the route once, but allow custom icon
  Route.Get('/favicon.ico', GetFavIcon);
  fFavIconRouted := true;
end;

function THttpServerGeneric.GetFavIcon(Ctxt: THttpServerRequestAbstract): cardinal;
begin
  if fFavIcon = '' then
    result := HTTP_NOTFOUND
  else if FindNameValue(pointer(Ctxt.InHeaders), 'IF-NONE-MATCH:') <> nil then
    result := HTTP_NOTMODIFIED
  else
  begin
    Ctxt.OutContent := fFavIcon;
    Ctxt.OutContentType := 'image/x-icon';
    Ctxt.OutCustomHeaders := 'Etag: "ok"';
    result := HTTP_SUCCESS;
  end;
end;

function THttpServerGeneric.NextConnectionID: integer;
begin
  result := InterlockedIncrement(fCurrentConnectionID);
  if result = maxInt - 2048 then
    fCurrentConnectionID := 0; // paranoid keep ID in positive 31-bit range
end;

procedure THttpServerGeneric.RegisterCompress(aFunction: THttpSocketCompress;
  aCompressMinSize: integer; aPriority: integer);
begin
  RegisterCompressFunc(
    fCompress, aFunction, fCompressAcceptEncoding, aCompressMinSize, aPriority);
end;

procedure THttpServerGeneric.Shutdown;
begin
  if self <> nil then
    fShutdownInProgress := true;
end;

function THttpServerGeneric.Request(Ctxt: THttpServerRequestAbstract): cardinal;
begin
  if (self = nil) or
     fShutdownInProgress or
     not Assigned(OnRequest) then
    result := HTTP_NOTFOUND
  else
  begin
    if Assigned(Ctxt.ConnectionThread) and
       Ctxt.ConnectionThread.InheritsFrom(TSynThread) and
       (not Assigned(TSynThread(Ctxt.ConnectionThread).StartNotified)) then
      NotifyThreadStart(TSynThread(Ctxt.ConnectionThread));
    result := OnRequest(Ctxt);
  end;
end;

function THttpServerGeneric.{%H-}Callback(Ctxt: THttpServerRequest;
  aNonBlocking: boolean): cardinal;
begin
  raise EHttpServer.CreateUtf8('%.Callback is not implemented: try to use ' +
    'another communication protocol, e.g. WebSockets', [self]);
end;

procedure THttpServerGeneric.AsyncResponse(Connection: TConnectionAsyncHandle;
  const Content, ContentType: RawUtf8; Status: cardinal);
begin
  EHttpServer.RaiseUtf8('%.AsyncResponse is not implemented: try to use ' +
    'another server class, e.g. THttpAsyncServer', [self]);
end;

procedure THttpServerGeneric.AsyncResponseFmt(Connection: TConnectionAsyncHandle;
  const ContentFmt: RawUtf8; const Args: array of const;
  const ContentType: RawUtf8; Status: cardinal);
var
  json: RawUtf8;
begin
  FormatUtf8(ContentFmt, Args, json);
  AsyncResponse(Connection, json, ContentType, Status);
end;

procedure THttpServerGeneric.AsyncResponseJson(Connection: TConnectionAsyncHandle;
  Value: pointer; TypeInfo: PRttiInfo; Status: cardinal);
var
  json: RawUtf8;
begin
  SaveJson(Value^, TypeInfo, [], json);
  AsyncResponse(Connection, json, JSON_CONTENT_TYPE_VAR, Status);
end;

procedure THttpServerGeneric.AsyncResponseError(
  Connection: TConnectionAsyncHandle; const Message: RawUtf8; Status: cardinal);
begin
  AsyncResponse(Connection, Message, TEXT_CONTENT_TYPE, Status);
end;

procedure THttpServerGeneric.ParseRemoteIPConnID(const Headers: RawUtf8;
  var RemoteIP: RawUtf8; var RemoteConnID: THttpServerConnectionID);
var
  P: PUtf8Char;
begin
  if self = nil then // = nil e.g. from TRtspOverHttpServer
    exit;
  // real Internet IP (replace RemoteIP='127.0.0.1' from a proxy)
  if fRemoteIPHeaderUpper <> '' then
    FindNameValue(Headers, pointer(fRemoteIPHeaderUpper),
      RemoteIP, {keepnotfound=}true);
  // real proxy connection ID
  if fRemoteConnIDHeaderUpper <> '' then
  begin
    P := FindNameValue(pointer(Headers), pointer(fRemoteConnIDHeaderUpper));
    if P <> nil then
      SetQWord(P, PQWord(@RemoteConnID)^);
  end;
  if RemoteConnID = 0 then
    // fallback to 31-bit sequence
    RemoteConnID := NextConnectionID;
end;

procedure THttpServerGeneric.AppendHttpDate(var Dest: TRawByteStringBuffer);
begin
  // overriden in THttpAsyncServer.AppendHttpDate with its own per-second cache
  Dest.AppendShort(HttpDateNowUtc);
end;

function THttpServerGeneric.CanNotifyCallback: boolean;
begin
  result := (self <> nil) and
            (fCallbackSendDelay <> nil);
end;

procedure THttpServerGeneric.SetRouterClass(aRouter: TRadixTreeNodeClass);
begin
  if fRouterClass <> nil then
    EHttpServer.RaiseUtf8('%.RouterClass already set', [self]);
  fRouterClass := aRouter;
end;

procedure THttpServerGeneric.SetServerName(const aName: RawUtf8);
begin
  fServerName := aName;
  FormatUtf8('Server: %'#13#10, [fServerName], fRequestHeaders);
  if not (hsoNoXPoweredHeader in fOptions) then
    Append(fRequestHeaders, XPOWEREDNAME + ': ' + XPOWEREDVALUE + #13#10);
  fDefaultRequestOptions := [];
  if hsoHeadersUnfiltered in fOptions then
    include(fDefaultRequestOptions, hroHeadersUnfiltered);
end;

procedure THttpServerGeneric.SetOptions(opt: THttpServerOptions);
begin
  if fOptions = opt then
    exit;
  fOptions := opt;
  SetServerName(fServerName); // recompute fRequestHeaders
end;

procedure THttpServerGeneric.SetOnRequest(
  const aRequest: TOnHttpServerRequest);
begin
  fOnRequest := aRequest;
end;

procedure THttpServerGeneric.SetOnBeforeBody(
  const aEvent: TOnHttpServerBeforeBody);
begin
  fOnBeforeBody := aEvent;
end;

procedure THttpServerGeneric.SetOnBeforeRequest(
  const aEvent: TOnHttpServerRequest);
begin
  fOnBeforeRequest := aEvent;
end;

procedure THttpServerGeneric.SetOnAfterRequest(
  const aEvent: TOnHttpServerRequest);
begin
  fOnAfterRequest := aEvent;
end;

procedure THttpServerGeneric.SetOnAfterResponse(
  const aEvent: TOnHttpServerAfterResponse);
begin
  fOnAfterResponse := aEvent;
end;

function THttpServerGeneric.DoBeforeRequest(Ctxt: THttpServerRequest): cardinal;
begin
  if Assigned(fOnBeforeRequest) then
    result := fOnBeforeRequest(Ctxt)
  else
    result := 0;
end;

function THttpServerGeneric.DoAfterRequest(Ctxt: THttpServerRequest): cardinal;
begin
  if Assigned(fOnAfterRequest) then
    result := fOnAfterRequest(Ctxt)
  else
    result := 0;
end;

procedure THttpServerGeneric.SetMaximumAllowedContentLength(aMax: Int64);
begin
  fMaximumAllowedContentLength := aMax;
end;

procedure THttpServerGeneric.SetRemoteIPHeader(const aHeader: RawUtf8);
begin
  fRemoteIPHeader := aHeader;
  fRemoteIPHeaderUpper := UpperCase(aHeader);
end;

procedure THttpServerGeneric.SetRemoteConnIDHeader(const aHeader: RawUtf8);
begin
  fRemoteConnIDHeader := aHeader;
  fRemoteConnIDHeaderUpper := UpperCase(aHeader);
end;


const
  // was generated from InitNetTlsContextSelfSignedServer commented lines
  PRIVKEY_PFX: array[0..2400] of byte = (
    $30, $82, $09, $5d, $02, $01, $03, $30, $82, $09, $27, $06, $09, $2a, $86, $48,
    $86, $f7, $0d, $01, $07, $01, $a0, $82, $09, $18, $04, $82, $09, $14, $30, $82,
    $09, $10, $30, $82, $03, $c7, $06, $09, $2a, $86, $48, $86, $f7, $0d, $01, $07,
    $06, $a0, $82, $03, $b8, $30, $82, $03, $b4, $02, $01, $00, $30, $82, $03, $ad,
    $06, $09, $2a, $86, $48, $86, $f7, $0d, $01, $07, $01, $30, $1c, $06, $0a, $2a,
    $86, $48, $86, $f7, $0d, $01, $0c, $01, $06, $30, $0e, $04, $08, $d4, $f9, $e6,
    $de, $12, $70, $dd, $ee, $02, $02, $08, $00, $80, $82, $03, $80, $3a, $91, $73,
    $2f, $46, $f9, $49, $00, $b6, $90, $5b, $59, $8f, $37, $6f, $19, $6f, $85, $ef,
    $01, $97, $1d, $cd, $a6, $c5, $04, $df, $0a, $0f, $87, $28, $59, $80, $9a, $88,
    $5f, $7f, $8b, $b2, $97, $a5, $13, $6e, $3e, $ab, $04, $b2, $5f, $62, $12, $0b,
    $30, $a5, $a7, $cc, $54, $9a, $8a, $6b, $6b, $8a, $7f, $0c, $cd, $af, $bb, $ea,
    $78, $a5, $7f, $11, $85, $13, $6f, $db, $61, $40, $d2, $26, $7c, $eb, $99, $a2,
    $6f, $1b, $a4, $71, $77, $44, $7a, $10, $ec, $02, $3d, $26, $48, $72, $77, $10,
    $07, $9e, $fe, $75, $20, $7a, $3b, $f2, $d8, $74, $74, $e8, $5c, $ff, $12, $df,
    $6c, $ed, $54, $c1, $76, $29, $d7, $2d, $dd, $fa, $3a, $32, $26, $7d, $f0, $31,
    $cf, $2d, $06, $37, $83, $9b, $39, $92, $2b, $78, $1d, $17, $1a, $d3, $4b, $24,
    $70, $00, $9f, $66, $8d, $3d, $be, $05, $e3, $63, $7c, $2e, $58, $f7, $db, $6d,
    $4f, $3e, $36, $cf, $0b, $c5, $5f, $b1, $ae, $6d, $e2, $61, $63, $12, $4c, $99,
    $24, $3e, $c9, $cf, $b9, $97, $20, $4a, $55, $41, $35, $f1, $6c, $43, $9f, $67,
    $63, $da, $14, $31, $57, $d2, $13, $b2, $ab, $59, $6b, $30, $d7, $1d, $2c, $54,
    $ed, $73, $0c, $2d, $aa, $f9, $11, $13, $64, $88, $56, $d8, $b6, $16, $f9, $e7,
    $9c, $03, $da, $87, $2f, $7b, $4b, $c2, $ee, $1b, $2c, $53, $06, $74, $d2, $11,
    $7f, $81, $31, $e8, $ee, $84, $40, $27, $1c, $18, $fa, $66, $02, $b1, $67, $42,
    $4a, $b9, $4d, $8b, $96, $95, $6b, $ab, $1a, $48, $47, $44, $0e, $63, $2c, $26,
    $27, $7c, $c1, $c8, $7c, $74, $b8, $1c, $f5, $9d, $6f, $09, $0f, $27, $f0, $b0,
    $46, $68, $0c, $99, $03, $80, $e5, $81, $2b, $74, $e6, $b4, $02, $12, $ad, $ef,
    $a8, $e6, $be, $36, $bf, $24, $2b, $ab, $b5, $4d, $33, $7d, $cd, $a0, $db, $6d,
    $19, $68, $c9, $00, $db, $a3, $d7, $02, $a8, $8a, $fb, $2f, $71, $4a, $a7, $82,
    $06, $cd, $bc, $e3, $88, $12, $ca, $35, $66, $66, $36, $cf, $2d, $e9, $97, $f8,
    $c1, $03, $48, $9c, $7a, $f4, $5f, $f5, $bc, $fd, $67, $62, $90, $19, $25, $62,
    $03, $b2, $b1, $ae, $27, $ff, $a0, $d5, $47, $0e, $a1, $21, $29, $c8, $a5, $19,
    $d3, $d5, $f1, $0c, $51, $5b, $4a, $db, $fb, $d8, $a6, $49, $db, $3a, $8e, $9d,
    $64, $be, $24, $01, $80, $f0, $35, $4e, $da, $83, $5a, $db, $83, $d7, $7c, $01,
    $1b, $5c, $8f, $b3, $d7, $b7, $49, $9f, $af, $c7, $29, $87, $4d, $73, $ef, $d0,
    $d7, $be, $bf, $c2, $09, $60, $bb, $fc, $5b, $64, $24, $04, $e6, $09, $9a, $19,
    $68, $61, $9c, $da, $62, $5e, $a4, $8a, $38, $5d, $de, $bd, $4f, $bf, $78, $04,
    $6d, $ce, $9a, $e2, $e4, $e7, $93, $a1, $e9, $ca, $f1, $3d, $9b, $e5, $14, $c8,
    $98, $fb, $29, $b0, $1f, $01, $48, $40, $80, $67, $2b, $f2, $30, $21, $1e, $a9,
    $4a, $b4, $8c, $be, $dd, $9b, $3e, $2d, $82, $37, $63, $51, $24, $17, $ac, $9a,
    $49, $bd, $af, $df, $2c, $ce, $bc, $d5, $a9, $43, $1f, $7a, $9a, $bf, $7b, $5a,
    $3e, $f3, $12, $55, $67, $7d, $97, $9b, $b6, $35, $4f, $d4, $97, $df, $2c, $d9,
    $40, $32, $1b, $92, $8e, $25, $6e, $f0, $7a, $48, $41, $2b, $9f, $55, $7e, $d2,
    $e5, $58, $85, $ba, $73, $51, $5c, $3f, $95, $18, $f6, $9b, $6a, $8d, $85, $25,
    $a2, $5e, $f0, $4f, $f7, $96, $51, $ca, $ac, $ff, $c9, $cc, $96, $4f, $c6, $b0,
    $63, $60, $c1, $50, $9a, $5b, $0d, $ca, $8f, $19, $cc, $87, $89, $6a, $31, $0f,
    $10, $df, $c8, $26, $64, $09, $2e, $59, $94, $22, $24, $e7, $5b, $59, $eb, $86,
    $f9, $99, $ee, $39, $28, $14, $0c, $a7, $c4, $1f, $b5, $69, $93, $c1, $cc, $dc,
    $14, $35, $de, $a8, $ea, $14, $6f, $c0, $d3, $13, $98, $2a, $a9, $55, $d6, $b6,
    $d4, $84, $0c, $92, $b2, $64, $28, $b5, $0f, $89, $a4, $f2, $7f, $3b, $3c, $35,
    $5d, $0b, $4a, $42, $6b, $cf, $b4, $70, $78, $b3, $5e, $3e, $3d, $6e, $86, $29,
    $5f, $f0, $27, $9a, $31, $a5, $6f, $94, $ab, $22, $8d, $e7, $fb, $21, $72, $da,
    $5a, $cf, $7b, $6a, $23, $f7, $6c, $05, $6d, $e1, $17, $24, $36, $7c, $3f, $56,
    $a7, $f4, $96, $8d, $b1, $9e, $d1, $90, $f0, $9d, $f8, $32, $4b, $24, $b5, $5b,
    $30, $b6, $b1, $3e, $9d, $d0, $fc, $56, $19, $41, $0a, $90, $cb, $e2, $bf, $e4,
    $55, $d1, $f1, $14, $af, $90, $b2, $13, $4e, $16, $2a, $1b, $43, $d9, $34, $14,
    $17, $c8, $8a, $fe, $1c, $a0, $66, $40, $5e, $6b, $9f, $ee, $15, $bf, $90, $d7,
    $6d, $87, $e2, $03, $10, $2a, $ff, $18, $e5, $a1, $da, $00, $9b, $b7, $e6, $1e,
    $3c, $5c, $8a, $36, $1e, $33, $e9, $4d, $89, $da, $6c, $49, $2f, $0d, $7b, $54,
    $68, $30, $b3, $ac, $af, $5f, $6f, $ff, $cb, $ee, $d7, $21, $28, $73, $7d, $32,
    $32, $d5, $c2, $74, $08, $c3, $01, $7e, $80, $c1, $f4, $cb, $ac, $91, $05, $5d,
    $b3, $d2, $b6, $95, $d4, $d0, $19, $b8, $25, $46, $d2, $ea, $17, $3a, $bf, $d3,
    $ff, $dc, $a1, $85, $a8, $56, $01, $1c, $24, $55, $bb, $2d, $6d, $7a, $07, $ac,
    $c3, $1a, $dc, $93, $97, $60, $9b, $6f, $aa, $4c, $2e, $61, $86, $30, $82, $05,
    $41, $06, $09, $2a, $86, $48, $86, $f7, $0d, $01, $07, $01, $a0, $82, $05, $32,
    $04, $82, $05, $2e, $30, $82, $05, $2a, $30, $82, $05, $26, $06, $0b, $2a, $86,
    $48, $86, $f7, $0d, $01, $0c, $0a, $01, $02, $a0, $82, $04, $ee, $30, $82, $04,
    $ea, $30, $1c, $06, $0a, $2a, $86, $48, $86, $f7, $0d, $01, $0c, $01, $03, $30,
    $0e, $04, $08, $04, $e0, $0a, $b0, $d6, $79, $a5, $44, $02, $02, $08, $00, $04,
    $82, $04, $c8, $7f, $48, $8d, $d1, $ab, $5e, $a1, $d8, $d0, $63, $62, $6a, $d2,
    $af, $dd, $20, $de, $91, $4d, $9a, $2f, $78, $20, $0c, $84, $a2, $c9, $38, $69,
    $fe, $8a, $aa, $8e, $b6, $3e, $4e, $d7, $ca, $f4, $2e, $6b, $d6, $9d, $c0, $3b,
    $5a, $4e, $7b, $89, $b8, $86, $38, $29, $87, $08, $a4, $b0, $2a, $ed, $ca, $13,
    $b2, $fe, $15, $3e, $87, $bd, $1d, $ad, $43, $1f, $62, $93, $c1, $b8, $9f, $93,
    $46, $74, $b3, $f4, $34, $d3, $9c, $97, $e1, $38, $09, $4c, $f4, $19, $35, $81,
    $34, $27, $93, $c7, $b3, $fa, $af, $58, $46, $73, $cc, $56, $91, $9f, $c8, $dc,
    $6b, $04, $af, $f1, $67, $65, $3d, $2c, $8e, $d1, $cc, $ac, $b7, $94, $41, $ea,
    $56, $c4, $45, $ed, $c9, $2c, $bb, $c1, $0f, $05, $06, $73, $03, $33, $d1, $c2,
    $bc, $34, $b2, $d5, $ea, $78, $5a, $22, $ca, $c3, $b4, $31, $43, $47, $92, $e8,
    $b4, $21, $f2, $70, $0e, $b5, $1b, $9a, $07, $86, $45, $66, $8f, $dd, $90, $2e,
    $9b, $af, $9f, $d4, $04, $42, $ec, $07, $78, $c8, $66, $0f, $19, $ae, $64, $f6,
    $99, $11, $6c, $71, $db, $58, $f2, $ce, $13, $29, $ff, $c2, $4a, $c7, $4a, $02,
    $d8, $28, $f7, $54, $dc, $a8, $fb, $30, $df, $53, $98, $85, $6d, $3c, $cf, $16,
    $93, $b9, $8b, $f5, $39, $80, $cd, $84, $36, $0a, $0f, $2f, $a2, $9e, $cb, $9b,
    $83, $f0, $49, $c5, $34, $b9, $4b, $1d, $5a, $46, $56, $8f, $a8, $05, $e0, $4c,
    $51, $41, $a4, $6b, $07, $38, $af, $f4, $43, $81, $8d, $7d, $54, $dd, $85, $da,
    $39, $2b, $0e, $ef, $44, $90, $e8, $99, $67, $65, $32, $5b, $f1, $ca, $1f, $cd,
    $58, $2d, $b3, $1e, $10, $4f, $b5, $6e, $23, $a0, $26, $d3, $22, $a7, $d9, $bd,
    $cc, $e6, $25, $52, $fe, $00, $70, $b3, $a8, $e6, $be, $42, $ae, $09, $7a, $ad,
    $46, $ec, $03, $a5, $12, $d4, $07, $23, $a7, $9e, $7e, $42, $00, $48, $13, $96,
    $e5, $3b, $55, $13, $2b, $a6, $e6, $6c, $9a, $25, $e0, $53, $27, $b5, $e7, $5f,
    $2b, $96, $b3, $7c, $77, $a9, $d7, $f7, $14, $c7, $a8, $e1, $19, $0f, $5c, $88,
    $e4, $f2, $1c, $ad, $71, $e8, $8f, $b2, $f6, $88, $b9, $2a, $57, $63, $ef, $b5,
    $d7, $ca, $7c, $95, $14, $5e, $9d, $21, $6c, $6f, $87, $37, $88, $b5, $5e, $f1,
    $8e, $0c, $33, $4b, $32, $a5, $ad, $3c, $b8, $e1, $bc, $1c, $74, $c2, $36, $d4,
    $14, $37, $96, $1f, $3d, $93, $ef, $23, $5a, $59, $b5, $13, $cd, $34, $c7, $d6,
    $78, $f5, $de, $1b, $38, $ec, $70, $d3, $9e, $d4, $08, $ef, $b7, $9c, $34, $14,
    $12, $9a, $7d, $d0, $7a, $09, $74, $16, $5f, $0e, $88, $cf, $f4, $d7, $f7, $30,
    $97, $d7, $d2, $18, $ff, $c7, $62, $8d, $37, $d0, $77, $66, $fd, $b3, $ee, $86,
    $d9, $1b, $9e, $7c, $d0, $d5, $b8, $d7, $f1, $3c, $57, $be, $51, $07, $a5, $25,
    $37, $e4, $73, $5e, $60, $b7, $98, $99, $6a, $c1, $f0, $35, $ff, $f6, $d7, $12,
    $44, $7b, $1e, $70, $bf, $32, $e2, $49, $58, $78, $41, $22, $ee, $b5, $99, $2b,
    $08, $c6, $a3, $e2, $c6, $65, $06, $8e, $d1, $fb, $cb, $2d, $d9, $0b, $92, $d2,
    $05, $ab, $91, $ea, $43, $62, $16, $b3, $4b, $73, $7a, $bd, $c5, $41, $a0, $2d,
    $6d, $28, $44, $a2, $93, $62, $2e, $67, $6b, $4a, $a0, $ab, $5e, $20, $a2, $f3,
    $00, $56, $b4, $a8, $e8, $a3, $da, $08, $99, $83, $c2, $ad, $8a, $7f, $85, $70,
    $3e, $ce, $2f, $39, $06, $77, $a8, $77, $3e, $bf, $e5, $c8, $38, $dc, $68, $28,
    $35, $49, $c8, $a8, $e3, $fd, $9d, $05, $dc, $70, $4c, $a2, $0d, $2c, $44, $37,
    $f4, $f3, $b8, $0a, $99, $3c, $97, $10, $92, $77, $58, $b2, $e3, $00, $a2, $0e,
    $34, $af, $5f, $c6, $1d, $22, $dd, $34, $57, $dc, $5b, $f1, $f1, $6e, $03, $12,
    $c2, $6c, $ad, $75, $03, $bf, $cd, $7a, $cd, $52, $0a, $75, $a1, $31, $b5, $19,
    $df, $52, $09, $3b, $94, $76, $ee, $1a, $5a, $a8, $8d, $3b, $ee, $b7, $86, $c6,
    $65, $c7, $e8, $0b, $3c, $b9, $ee, $7d, $80, $22, $89, $3d, $f8, $6c, $9e, $4f,
    $6e, $c8, $f8, $3a, $54, $76, $b5, $89, $6b, $05, $a5, $c9, $68, $68, $0b, $33,
    $e5, $55, $e8, $b2, $f9, $39, $dc, $c8, $0a, $13, $94, $01, $d2, $a1, $0a, $42,
    $f5, $37, $a4, $18, $c9, $97, $bb, $a4, $93, $4c, $49, $bb, $fb, $b0, $f5, $4e,
    $c5, $d3, $3b, $bd, $a0, $37, $10, $9f, $8f, $e7, $bb, $8a, $6d, $fe, $c3, $6c,
    $36, $a6, $3d, $c6, $ed, $d0, $7d, $68, $37, $11, $22, $16, $82, $ab, $c4, $02,
    $ec, $eb, $a0, $7d, $0e, $22, $79, $ce, $6a, $39, $45, $31, $5c, $99, $75, $c3,
    $6a, $b9, $a1, $00, $2d, $4d, $4d, $f5, $ac, $cc, $1e, $0d, $36, $a7, $36, $40,
    $53, $6c, $a8, $6c, $b0, $f8, $27, $30, $68, $ae, $06, $39, $a5, $89, $86, $cc,
    $bb, $b0, $ca, $43, $62, $1d, $71, $6a, $30, $62, $b9, $bc, $dc, $8a, $d1, $23,
    $04, $6f, $35, $4b, $6f, $81, $b8, $31, $91, $26, $83, $28, $e6, $2e, $d3, $84,
    $fb, $53, $f9, $6f, $b0, $0e, $37, $e1, $ce, $4d, $6f, $35, $14, $37, $4b, $ee,
    $31, $46, $ee, $85, $df, $04, $0d, $3d, $f0, $ac, $d2, $b7, $ef, $ae, $87, $7a,
    $a8, $c0, $9f, $98, $4e, $e9, $c0, $a6, $7c, $e9, $ff, $d7, $76, $72, $82, $ca,
    $89, $fb, $94, $9c, $67, $7a, $47, $47, $5c, $2c, $17, $61, $96, $15, $d6, $26,
    $bb, $0f, $ef, $f0, $c7, $23, $ba, $39, $8a, $08, $b5, $f3, $68, $de, $54, $80,
    $15, $a3, $43, $a5, $da, $0b, $60, $fe, $f9, $bf, $54, $fe, $21, $34, $08, $ab,
    $0d, $59, $a8, $dc, $8e, $7b, $54, $46, $4d, $f7, $b6, $ac, $df, $1d, $6f, $50,
    $9c, $3c, $17, $5d, $19, $4c, $48, $21, $d2, $5b, $f0, $6f, $a7, $2b, $d4, $b0,
    $87, $fd, $42, $d0, $87, $d3, $be, $7a, $01, $61, $16, $8a, $a3, $bc, $83, $1d,
    $bb, $6a, $fb, $51, $eb, $6b, $37, $f9, $1e, $e8, $ff, $0a, $4f, $46, $14, $1c,
    $04, $ee, $cd, $8d, $4a, $33, $cd, $8d, $4f, $0b, $24, $2c, $e1, $25, $48, $42,
    $a2, $eb, $04, $f4, $7e, $30, $62, $ae, $cc, $20, $1a, $a6, $38, $5c, $d5, $f3,
    $27, $07, $81, $75, $9c, $f4, $d0, $87, $79, $6f, $0a, $28, $3d, $a5, $22, $b8,
    $ec, $c7, $b3, $c0, $f5, $de, $77, $6c, $7f, $c3, $01, $1e, $fa, $88, $83, $bb,
    $d0, $9c, $29, $82, $11, $db, $d0, $99, $c7, $d8, $e0, $2f, $e0, $22, $22, $0d,
    $2a, $e7, $29, $64, $b3, $72, $a2, $08, $5a, $fa, $08, $86, $d4, $e5, $fe, $05,
    $08, $64, $cc, $c3, $53, $7f, $9a, $2e, $93, $21, $c2, $fa, $16, $37, $3e, $28,
    $cf, $ca, $57, $da, $bb, $15, $1a, $c6, $41, $39, $be, $d7, $f9, $9e, $78, $1b,
    $83, $a7, $6d, $1e, $22, $be, $49, $7f, $64, $41, $5d, $a8, $11, $40, $d7, $ad,
    $43, $f6, $c3, $9e, $7e, $3a, $95, $2d, $27, $04, $80, $95, $02, $60, $a6, $a6,
    $55, $25, $bd, $64, $e2, $d0, $99, $b5, $d9, $4b, $42, $f5, $69, $ce, $9a, $fe,
    $26, $d1, $c4, $9e, $29, $3d, $af, $85, $2f, $8e, $e0, $0a, $69, $f2, $69, $ee,
    $66, $c2, $f7, $ab, $81, $bc, $82, $01, $22, $b6, $45, $31, $25, $30, $23, $06,
    $09, $2a, $86, $48, $86, $f7, $0d, $01, $09, $15, $31, $16, $04, $14, $11, $9c,
    $ab, $d1, $44, $93, $91, $54, $3c, $52, $a0, $66, $4c, $a5, $99, $db, $42, $62,
    $d2, $43, $30, $2d, $30, $21, $30, $09, $06, $05, $2b, $0e, $03, $02, $1a, $05,
    $00, $04, $14, $e0, $d8, $41, $1f, $76, $85, $94, $b5, $64, $2d, $fd, $59, $27,
    $ce, $ea, $3b, $b1, $e2, $25, $11, $04, $08, $01, $3e, $2b, $1b, $94, $cf, $41,
    $11);

function PrivKeyCertPfx: RawByteString;
begin
  FastSetRawByteString(result, @PRIVKEY_PFX, SizeOf(PRIVKEY_PFX));
end;

procedure InitNetTlsContextSelfSignedServer(var TLS: TNetTlsContext;
  Algo: TCryptAsymAlgo; UsePreComputed: boolean);
var
  cert: ICryptCert;
  certfile, keyfile: TFileName;
  keypass: RawUtf8;
begin
  certfile := TemporaryFileName;
  if UsePreComputed or
     (CryptCertOpenSsl[Algo] = nil) then
     // we can't use CryptCertX509[] because SSPI requires PFX binary format
  begin
    FileFromString(PrivKeyCertPfx, certfile); // use pre-computed key
    keypass := 'pass';
    // warning: will work with SSPI but NOT with OpenSSL
  end
  else
  begin
    keyfile := TemporaryFileName;
    keypass := CardinalToHexLower(Random32Not0);
    cert := CryptCertOpenSsl[Algo].
              Generate(CU_TLS_SERVER, '127.0.0.1', nil, 3650);
    cert.SaveToFile(certfile, cccCertOnly, '', ccfPem);
    cert.SaveToFile(keyfile, cccPrivateKeyOnly, keypass, ccfPem);
    //writeln(BinToSource('PRIVKEY_PFX', '',
    //  cert.Save(cccCertWithPrivateKey, 'pass', ccfBinary)));
  end;
  InitNetTlsContext(TLS, {server=}true, certfile, keyfile, keypass);
end;

const
  // RLE-encoded /favicon.ico, as decoded into FavIconBinary function result
  // - using Base64 encoding is the easiest with Delphi and RawByteString :)
  _FAVICON_BINARY: RawUtf8 =
    'aQOi9AjOyJ+H/gMAAAEAAQAYGBAAAQAEAOgBAAAWAAAAKAAAABgAAAAwAAAAAQAEWhEAEFoH' +
    'AAEC7wAFBQgAVVVVAAMDwwCMjIwA////AG1tcQCjo6sACQmbADU1NgAAACsACAhPAMvLywAA' +
    'AHEADy34AABu/QBaEFVXYiJnWgdVUmd8zHdmWgVVVmRCERESRGRaBFUiYVoEERlmZVVVUiIR' +
    'ERqqERESJlVVdiERq93d26ERIsVVZBEa2DMziNoRFiVUdhGtgzAAM42hFHzCQRG4MAAAADix' +
    'EUJCYRrTWgQAM9oRYiIhG4MAAOAAA4oRIpKRG4MAD/4AA4oRIpKRG4MADv4AA4oRIiIhGoMA' +
    'AAAOA9oRKUlhStMwAAAAONERKVJhmbgzDuADOLF5ZlxEERuDMzMzixmUZVVEkRG9Z3eNsREk' +
    'RVVWQRGWu7u2kRlGVVVcJJGUzMzEESQlVVVVwndaBBGXcsVaBFVnd3REd3RlWgZVR3zMdEVV' +
    'VVX///8A/4D/AP4APwD4AA8A8AAHAOAAAwDAAAEAwAABAIBaHwCAAAAAgAABAMAAAQDgAAMA' +
    '4AAHAPAABwD8AB8A/wB/AA==';

var
  _FavIconBinary: RawByteString;

function FavIconBinary: RawByteString;
begin
  if _FavIconBinary = '' then
    _FavIconBinary := AlgoRle.Decompress(Base64ToBin(_FAVICON_BINARY));
  result := _FavIconBinary;
end;

var
  GetMacAddressSafe: TLightLock; // to protect the filter global variable
  GetMacAddressFilter: TMacAddressFilter;

const
  NETHW_ORDER: array[TMacAddressKind] of byte = ( // Kind to sort priority
    2,  // makUndefined
    0,  // makEthernet
    1,  // makWifi
    4,  // makTunnel
    3,  // makPpp
    5,  // makCellular
    6); // makSoftware

function SortByMacAddressFilter(const A, B): integer;
var
  ma: TMacAddress absolute A;
  mb: TMacAddress absolute B;
begin
  // sort by kind
  if not (mafIgnoreKind in GetMacAddressFilter) then
  begin
    result := CompareCardinal(NETHW_ORDER[ma.Kind], NETHW_ORDER[mb.Kind]);
    if result <> 0 then
      exit;
  end;
  // sort with gateway first
  if not (mafIgnoreGateway in GetMacAddressFilter) then
  begin
    result := ord(ma.Gateway = '') - ord(mb.Gateway = '');
    if result <> 0 then
      exit;
  end;
  // sort by speed within this kind and gateway
  if not (mafIgnoreSpeed in GetMacAddressFilter) then
  begin
    result := CompareCardinal(mb.Speed, ma.Speed);
    if result <> 0 then
      exit;
  end;
  // fallback to sort by IfIndex
  result := CompareCardinal(ma.IfIndex, mb.IfIndex);
end;

function GetMainMacAddress(out Mac: TMacAddress; Filter: TMacAddressFilter): boolean;
var
  allowed, available: TMacAddressKinds;
  all: TMacAddressDynArray;
  arr: TDynArray;
  i, bct: PtrInt;
begin
  result := false;
  all := copy(GetMacAddresses({upanddown=}false));
  if all = nil then
    exit;
  arr.Init(TypeInfo(TMacAddressDynArray), all);
  bct := 0;
  available := [];
  for i := 0 to high(all) do
    with all[i] do
    begin
      include(available, Kind);
      if Broadcast <> '' then
        inc(bct);
      {writeln(Kind, ' ', Address,' name=',Name,' ifindex=',IfIndex,
         ' ip=',ip,' netmask=',netmask,' broadcast=',broadcast);}
    end;
  allowed := [];
  if mafLocalOnly in Filter then
    allowed := [makEthernet, makWifi]
  else if mafEthernetOnly in Filter then
    include(allowed, makEthernet);
  if (available * allowed) <> [] then // e.g. if all makUndefined
    for i := high(all) downto 0 do
      if not (all[i].Kind in allowed) then
        arr.Delete(i);
  if (mafRequireBroadcast in Filter) and
     (bct <> 0) then
    for i := high(all) downto 0 do
      if all[i].Broadcast = '' then
        arr.Delete(i);
  if all = nil then
    exit;
  if length(all) > 1 then
  begin
    GetMacAddressSafe.Lock; // protect GetMacAddressFilter global variable
    try
      GetMacAddressFilter := Filter;
      arr.Sort(SortByMacAddressFilter);
    finally
      GetMacAddressSafe.UnLock;
    end;
  end;
  Mac := all[0];
  result := true;
end;

function GetMainMacAddress(out Mac: TMacAddress;
  const InterfaceNameAddressOrIP: RawUtf8; UpAndDown: boolean): boolean;
var
  i: PtrInt;
  all: TMacAddressDynArray;
  pattern, ip4: cardinal;
  m, fnd: ^TMacAddress;
begin
  // retrieve the current network interfaces
  result := false;
  if InterfaceNameAddressOrIP = '' then
    exit;
  all := GetMacAddresses(UpAndDown); // from cache
  if all = nil then
    exit;
  // search for exact Name / Address / IP
  m := pointer(all);
  for i := 1 to length(all) do
    if IdemPropNameU(m^.Name, InterfaceNameAddressOrIP) or
       IdemPropNameU(m^.Address, InterfaceNameAddressOrIP) or
       (m^.IP = InterfaceNameAddressOrIP) then
    begin
      Mac := m^;
      result := true;
      exit;
    end
    else
      inc(m);
  // fallback to search as network bitmask pattern
  if not IPToCardinal(InterfaceNameAddressOrIP, pattern) then
    exit;
  fnd := nil;
  m := pointer(all);
  for i := 1 to length(all) do
  begin
    if IPToCardinal(m^.IP, ip4) and
       (ip4 and pattern = ip4) and // e.g. 192.168.1.2 and 192.168.1.255
       ((fnd = nil) or
        (NETHW_ORDER[m^.Kind] < NETHW_ORDER[fnd^.Kind])) then
      fnd := m; // pickup the interface with the best hardware (paranoid)
    inc(m);
  end;
  if fnd = nil then
    exit;
  Mac := fnd^;
  result := true;
end;


{ ******************** THttpServerSocket/THttpServer HTTP/1.1 Server }

{ THttpServerSocketGeneric }

constructor THttpServerSocketGeneric.Create(const aPort: RawUtf8;
  const OnStart, OnStop: TOnNotifyThread; const ProcessName: RawUtf8;
  ServerThreadPoolCount: integer; KeepAliveTimeOut: integer;
  ProcessOptions: THttpServerOptions);
begin
  fSockPort := aPort;
  fCompressGz := -1;
  SetServerKeepAliveTimeOut(KeepAliveTimeOut); // 30 seconds by default
  // event handlers set before inherited Create to be visible in childs
  fOnThreadStart := OnStart;
  SetOnTerminate(OnStop);
  fProcessName := ProcessName; // TSynThreadPoolTHttpServer needs it now
  inherited Create(OnStart, OnStop, ProcessName, ProcessOptions);
end;

function THttpServerSocketGeneric.GetApiVersion: RawUtf8;
begin
  result := SocketApiVersion;
end;

function THttpServerSocketGeneric.GetRegisterCompressGzStatic: boolean;
begin
  result := fCompressGz >= 0;
end;

procedure THttpServerSocketGeneric.SetRegisterCompressGzStatic(Value: boolean);
begin
  if Value then
    fCompressGz := CompressIndex(fCompress, @CompressGzip)
  else
    fCompressGz := -1;
end;

function THttpServerSocketGeneric.{%H-}WebSocketsEnable(const aWebSocketsURI,
  aWebSocketsEncryptionKey: RawUtf8; aWebSocketsAjax: boolean;
  aWebSocketsBinaryOptions: TWebSocketProtocolBinaryOptions): pointer;
begin
  raise EHttpServer.CreateUtf8('Unexpected %.WebSocketEnable: requires ' +
    'HTTP_BIDIR (useBidirSocket or useBidirAsync) kind of server', [self]);
end;

procedure THttpServerSocketGeneric.WaitStarted(Seconds: integer;
  const CertificateFile, PrivateKeyFile: TFileName;
  const PrivateKeyPassword: RawUtf8; const CACertificatesFile: TFileName);
var
  tls: TNetTlsContext;
begin
  InitNetTlsContext(tls, {server=}true,
    CertificateFile, PrivateKeyFile, PrivateKeyPassword, CACertificatesFile);
  WaitStarted(Seconds, @tls);
end;

procedure THttpServerSocketGeneric.WaitStarted(
  Seconds: integer; TLS: PNetTlsContext);
var
  tix: Int64;
begin
  tix := mormot.core.os.GetTickCount64 + Seconds * 1000; // never wait forever
  repeat
    if Terminated then
      exit;
    case GetExecuteState of
      esRunning:
        break;
      esFinished:
        EHttpServer.RaiseUtf8('%.Execute aborted due to %',
          [self, fExecuteMessage]);
    end;
    Sleep(1); // warning: waits typically 1-15 ms on Windows
    if mormot.core.os.GetTickCount64 > tix then
      EHttpServer.RaiseUtf8('%.WaitStarted timeout after % seconds [%]',
        [self, Seconds, fExecuteMessage]);
  until false;
  // now the server socket has been bound, and is ready to accept connections
  if (hsoEnableTls in fOptions) and
     (TLS <> nil) and
     (TLS^.CertificateFile <> '') and
     ((fSock = nil) or
      not fSock.TLS.Enabled) then
  begin
    if fSock = nil then
      Sleep(5); // paranoid on some servers which propagate the pointer
    if (fSock <> nil) and
       not fSock.TLS.Enabled then // call InitializeTlsAfterBind once
    begin
      fSock.TLS := TLS^;
      InitializeTlsAfterBind; // validate TLS certificate(s) now
      Sleep(1); // let some warmup happen
    end;
  end;
end;

procedure THttpServerSocketGeneric.WaitStartedHttps(Seconds: integer;
  UsePreComputed: boolean);
var
  net: TNetTlsContext;
begin
  InitNetTlsContextSelfSignedServer(net, caaRS256, UsePreComputed);
  try
    WaitStarted(Seconds, @net);
  finally
    DeleteFile(Utf8ToString(net.CertificateFile));
    DeleteFile(Utf8ToString(net.PrivateKeyFile));
  end;
end;

function THttpServerSocketGeneric.GetStat(
  one: THttpServerSocketGetRequestResult): integer;
begin
  result := fStats[one];
end;

procedure THttpServerSocketGeneric.IncStat(
  one: THttpServerSocketGetRequestResult);
begin
  if not (hsoNoStats in fOptions) then
    LockedInc32(@fStats[one]);
end;

function THttpServerSocketGeneric.HeaderRetrieveAbortTix: Int64;
begin
  result := fHeaderRetrieveAbortDelay;
  if result <> 0 then
    inc(result, mormot.core.os.GetTickCount64()); // FPC requires () on Windows
end;

function THttpServerSocketGeneric.DoRequest(Ctxt: THttpServerRequest): boolean;
var
  cod: integer;
begin
  result := false; // error
  try
    // first try any URI rewrite or direct callback execution
    if fRoute <> nil then
    begin
      cod := fRoute.Process(Ctxt);
      if cod <> 0 then
      begin
        if (Ctxt.OutContent = '') and
           (cod <> HTTP_ASYNCRESPONSE) and
           not StatusCodeIsSuccess(cod) then
        begin
          Ctxt.fErrorMessage := 'Wrong route';
          IncStat(grRejected);
        end;
        Ctxt.RespStatus := cod;
        result := true; // a callback was executed
        exit;
      end;
    end;
    // fallback to Request() / OnRequest main processing callback
    cod := DoBeforeRequest(Ctxt);
    if cod <> 0 then
    begin
      Ctxt.RespStatus := cod;
      if Ctxt.OutContent = '' then
        Ctxt.fErrorMessage := 'Rejected request';
      IncStat(grRejected);
    end
    else
    begin
      Ctxt.RespStatus := Request(Ctxt); // calls OnRequest event handler
      if Ctxt.InContent <> '' then
        Ctxt.InContent := ''; // release memory ASAP
      cod := DoAfterRequest(Ctxt);
      if cod > 0 then
        Ctxt.RespStatus := cod;
    end;
    result := true; // success
  except
    on E: Exception do
      begin
        // intercept and return Internal Server Error 500 on any fatal exception
        Ctxt.RespStatus := HTTP_SERVERERROR;
        Ctxt.SetErrorMessage('%: %', [E, E.Message]);
        IncStat(grException);
        // will keep soClose as result to shutdown the connection
      end;
  end;
end;

procedure THttpServerSocketGeneric.DoProgressiveRequestFree(
  var Ctxt: THttpRequestContext);
begin
  if Assigned(fOnProgressiveRequestFree) and
     (rfProgressiveStatic in Ctxt.ResponseFlags) then
    try
      fOnProgressiveRequestFree.Remove(@Ctxt);
      exclude(Ctxt.ResponseFlags, rfProgressiveStatic); // remove it once
    except
      ; // ignore any exception in callbacks
    end;
end;

procedure THttpServerSocketGeneric.SetServerKeepAliveTimeOut(Value: cardinal);
begin
  fServerKeepAliveTimeOut := Value;
  fServerKeepAliveTimeOutSec := Value div 1000;
end;

function THttpServerSocketGeneric.OnNginxAllowSend(
  Context: THttpServerRequestAbstract; const LocalFileName: TFileName): boolean;
var
  match, i, f: PtrInt;
  folderlefttrim: ^TFileName;
begin
  match := 0;
  folderlefttrim := pointer(fNginxSendFileFrom);
  if LocalFileName <> '' then
    for f := 1 to length(fNginxSendFileFrom) do
    begin
      match := length(folderlefttrim^);
      for i := 1 to match do // case sensitive left search
        if LocalFileName[i] <> folderlefttrim^[i] then
        begin
          match := 0;
          break;
        end;
      if match <> 0 then
        break; // found matching folderlefttrim
      inc(folderlefttrim);
    end;
  result := match <> 0;
  if not result then
    exit; // no match -> manual send
  Context.AddOutHeader(['X-Accel-Redirect: ',
    copy(Context.OutContent, match + 1, 1024)]); // remove '/var/www'
  Context.OutContent := '';
end;

procedure THttpServerSocketGeneric.NginxSendFileFrom(
  const FileNameLeftTrim: TFileName);
var
  n: PtrInt;
begin
  n := length(fNginxSendFileFrom);
  SetLength(fNginxSendFileFrom, n + 1);
  fNginxSendFileFrom[n] := FileNameLeftTrim;
  fOnSendFile := OnNginxAllowSend;
end;

procedure THttpServerSocketGeneric.InitializeTlsAfterBind;
begin
  if fSock.TLS.Enabled then
    exit;
  fSafe.Lock; // load certificates once from first connected thread
  try
    fSock.DoTlsAfter(cstaBind);  // validate certificates now
  finally
    fSafe.UnLock;
  end;
end;

procedure THttpServerSocketGeneric.SetAuthorizeNone;
begin
  fAuthorize := hraNone;
  fAuthorizerBasic := nil;
  fAuthorizerDigest := nil;
  fAuthorizeBasic := nil;
  fAuthorizeBasicRealm := '';
end;

procedure THttpServerSocketGeneric.SetAuthorizeDigest(
  const Digest: IDigestAuthServer);
begin
  SetAuthorizeNone;
  if Digest = nil then
    exit;
  fAuthorizerDigest := Digest;
  fAuthorize := hraDigest;
end;

procedure THttpServerSocketGeneric.SetAuthorizeBasic(
  const Basic: IBasicAuthServer);
begin
  SetAuthorizeNone;
  if Basic = nil then
    exit;
  fAuthorizerBasic := Basic;
  fAuthorize := hraBasic;
  fAuthorizeBasicRealm := Basic.BasicInit;
end;

procedure THttpServerSocketGeneric.SetAuthorizeBasic(const BasicRealm: RawUtf8;
  const OnBasicAuth: TOnHttpServerBasicAuth);
begin
  SetAuthorizeNone;
  if not Assigned(OnBasicAuth) then
    exit;
  fAuthorize := hraBasic;
  fAuthorizeBasic := OnBasicAuth;
  FormatUtf8('WWW-Authenticate: Basic realm="%"'#13#10, [BasicRealm],
    fAuthorizeBasicRealm);
end;

procedure THttpServerSocketGeneric.SetAuthorizeNegotiate;
begin
  SetAuthorizeNone;
  if not InitializeDomainAuth then
    EHttpServer.RaiseUtf8('%.SetAuthorizeNegotiate: no % available',
      [self, SECPKGNAMEAPI]);
   fAuthorize := hraNegotiate;
end;

function THttpServerSocketGeneric.AuthorizeServerMem: TDigestAuthServerMem;
begin
  result := nil;
  if self = nil then
    exit;
  if (fAuthorizerDigest <> nil) and
     fAuthorizerDigest.Instance.InheritsFrom(TDigestAuthServerMem) then
    result := TDigestAuthServerMem(fAuthorizerDigest.Instance)
  else if (fAuthorizerBasic <> nil) and
           fAuthorizerBasic.Instance.InheritsFrom(TDigestAuthServerMem) then
    result := TDigestAuthServerMem(fAuthorizerBasic.Instance)
end;

function THttpServerSocketGeneric.ComputeWwwAuthenticate(Opaque: Int64): RawUtf8;
begin
  // return the expected 'WWW-Authenticate: ####' header content
  result := '';
  case fAuthorize of
    hraBasic:
      result := fAuthorizeBasicRealm;
    hraDigest:
      if fAuthorizerDigest <> nil then
        result := fAuthorizerDigest.DigestInit(Opaque, 0);
    hraNegotiate:
      result := 'WWW-Authenticate: Negotiate'; // with no NTLM support
  end;
end;

function THttpServerSocketGeneric.Authorization(var Http: THttpRequestContext;
  Opaque: Int64): TAuthServerResult;
var
  auth, authend: PUtf8Char;
  user, pass, url: RawUtf8;
  bin, bout: RawByteString;
  ctx: TSecContext;
begin
  // parse the 'Authorization: basic/digest/negotiate <magic>' header
  try
    result := asrRejected;
    auth := FindNameValue(pointer(Http.Headers), 'AUTHORIZATION: ');
    if auth = nil then
      exit;
    case fAuthorize of
      hraBasic:
        if IdemPChar(auth, 'BASIC ') and
           BasicServerAuth(auth + 6, user, pass) then
          try
            if Assigned(fAuthorizeBasic) then
              if fAuthorizeBasic(self, user, pass) then
                result := asrMatch
              else
                result := asrIncorrectPassword
            else if Assigned(fAuthorizerBasic) then
              result := fAuthorizerBasic.CheckCredential(user, pass);
          finally
            FillZero(pass);
          end;
      hraDigest:
        if (fAuthorizerDigest <> nil) and
           IdemPChar(auth, 'DIGEST ') then
        begin
          result := fAuthorizerDigest.DigestAuth(
             auth + 7, Http.CommandMethod, Opaque, 0, user, url);
          if (result = asrMatch) and
             (url <> Http.CommandUri) then
            result := asrRejected;
        end;
      hraNegotiate:
        // simple implementation assuming a two-way Negotiate/Kerberos handshake
        // - see TRestServerAuthenticationSspi.Auth() for NTLM / three-way
        if IdemPChar(auth, 'NEGOTIATE ') then
        begin
          inc(auth, 10); // parse 'Authorization: Negotiate <base64 encoding>'
          authend := PosChar(auth, #13);
          if (authend = nil) or
             not Base64ToBin(PAnsiChar(auth), authend - auth, bin) or
             IdemPChar(pointer(bin), 'NTLM') then // two-way Kerberos only
            exit;
          InvalidateSecContext(ctx);
          try
            if ServerSspiAuth(ctx, bin, bout) then
            begin
              ServerSspiAuthUser(ctx, user);
              Http.ResponseHeaders := 'WWW-Authenticate: Negotiate ' +
                mormot.core.buffers.BinToBase64(bout) + #13#10;
              result := asrMatch;
            end;
          finally
            FreeSecContext(ctx);
          end;
        end
    else
      exit;
    end;
    if result = asrMatch then
      Http.BearerToken := user; // see THttpServerRequestAbstract.Prepare
  except
    result := asrRejected; // any processing error should silently fail the auth
  end
end;

function THttpServerSocketGeneric.SetRejectInCommandUri(
  var Http: THttpRequestContext; Opaque: Int64; Status: integer): boolean;
var
  reason, auth, body: RawUtf8;
begin
  StatusCodeToReason(status, reason);
  FormatUtf8('<!DOCTYPE html><html><head><title>%</title></head>' +
             '<body style="font-family:verdana"><h1>%</h1>' +
             '<p>Server rejected % request as % %.</body></html>',
    [reason, reason, Http.CommandUri, status, reason], body);
  result := (status = HTTP_UNAUTHORIZED) and
            (fAuthorize <> hraNone);
  if result then // don't close the connection but set grWwwAuthenticate
    auth := ComputeWwwAuthenticate(Opaque);
  FormatUtf8('HTTP/1.% % %'#13#10'%' + HTML_CONTENT_TYPE_HEADER +
    #13#10'Content-Length: %'#13#10#13#10'%',
    [ord(result), status, reason, auth, length(body), body], Http.CommandUri);
end;



{ THttpServer }

constructor THttpServer.Create(const aPort: RawUtf8;
  const OnStart, OnStop: TOnNotifyThread; const ProcessName: RawUtf8;
  ServerThreadPoolCount: integer; KeepAliveTimeOut: integer;
  ProcessOptions: THttpServerOptions);
begin
  if fThreadPool <> nil then
    fThreadPool.ContentionAbortDelay := 5000; // 5 seconds default
  fInternalHttpServerRespList := TSynObjectListLocked.Create({ownobject=}false);
  if fThreadRespClass = nil then
    fThreadRespClass := THttpServerResp;
  if fSocketClass = nil then
    fSocketClass := THttpServerSocket;
  fServerSendBufferSize := 256 shl 10; // 256KB seems fine on Windows + POSIX
  inherited Create(aPort, OnStart, OnStop, ProcessName, ServerThreadPoolCount,
    KeepAliveTimeOut, ProcessOptions);
  if hsoBan40xIP in ProcessOptions then
    fBanned := THttpAcceptBan.Create;
  if ServerThreadPoolCount > 0 then
  begin
    fThreadPool := TSynThreadPoolTHttpServer.Create(self, ServerThreadPoolCount);
    fHttpQueueLength := 1000;
    if hsoThreadCpuAffinity in ProcessOptions then
      SetServerThreadsAffinityPerCpu(nil, TThreadDynArray(fThreadPool.WorkThread))
    else if hsoThreadSocketAffinity in ProcessOptions then
      SetServerThreadsAffinityPerSocket(nil, TThreadDynArray(fThreadPool.WorkThread));
  end
  else if ServerThreadPoolCount < 0 then
    fMonoThread := true; // accept() + recv() + send() in a single thread
    // setting fHeaderRetrieveAbortDelay may be a good idea
end;

destructor THttpServer.Destroy;
var
  endtix: Int64;
  i: PtrInt;
  dummy: TNetSocket; // touch-and-go to the server to release main Accept()
begin
  Terminate; // set Terminated := true for THttpServerResp.Execute
  if fThreadPool <> nil then
    fThreadPool.fTerminated := true; // notify background process
  if (fExecuteState = esRunning) and
     (Sock <> nil) then
  begin
    if Sock.SocketLayer <> nlUnix then
      Sock.Close; // shutdown TCP/UDP socket to unlock Accept() in Execute
    if NewSocket(Sock.Server, Sock.Port, Sock.SocketLayer,
       {dobind=}false, 10, 10, 10, 0, dummy) = nrOK then
      // Windows TCP/UDP socket may not release Accept() until something happen
      dummy.ShutdownAndClose({rdwr=}false);
    if Sock.SockIsDefined then
      Sock.Close; // nlUnix expects shutdown after accept() returned
  end;
  endtix := mormot.core.os.GetTickCount64 + 20000;
  try
    if fInternalHttpServerRespList <> nil then // HTTP/1.1 long running threads
    begin
      fInternalHttpServerRespList.Safe.ReadOnlyLock; // notify
      for i := 0 to fInternalHttpServerRespList.Count - 1 do
        THttpServerResp(fInternalHttpServerRespList.List[i]).Shutdown;
      fInternalHttpServerRespList.Safe.ReadOnlyUnLock;
      repeat
        // wait for all THttpServerResp.Execute to be finished
        fInternalHttpServerRespList.Safe.ReadOnlyLock;
        try
          if (fInternalHttpServerRespList.Count = 0) and
             (fExecuteState <> esRunning) then
            break;
        finally
          fInternalHttpServerRespList.Safe.ReadOnlyUnLock;
        end;
        SleepHiRes(10);
      until mormot.core.os.GetTickCount64 > endtix;
      FreeAndNilSafe(fInternalHttpServerRespList);
    end;
  finally
    FreeAndNilSafe(fThreadPool); // release all associated threads
    FreeAndNilSafe(fSock);
    FreeAndNil(fBanned);
    inherited Destroy;       // direct Thread abort, no wait till ended
  end;
end;

function THttpServer.GetExecuteState: THttpServerExecuteState;
begin
  result := fExecuteState;
end;

function THttpServer.GetHttpQueueLength: cardinal;
begin
  result := fHttpQueueLength;
end;

procedure THttpServer.SetHttpQueueLength(aValue: cardinal);
begin
  fHttpQueueLength := aValue;
end;

function THttpServer.GetConnectionsActive: cardinal;
begin
  result := fServerConnectionActive;
end;

procedure THttpServer.Execute;
var
  cltsock: TNetSocket;
  cltaddr: TNetAddr;
  cltservsock: THttpServerSocket;
  res: TNetResult;
  banlen, sec, bansec, i: integer;
  tix64: QWord;
begin
  // THttpServerGeneric thread preparation: launch any OnHttpThreadStart event
  fExecuteState := esBinding;
  NotifyThreadStart(self);
  bansec := 0;
  // main server process loop
  try
    // BIND + LISTEN (TLS is done later)
    fSock := TCrtSocket.Bind(fSockPort, nlTcp, 5000, hsoReusePort in fOptions);
    fExecuteState := esRunning;
    if not fSock.SockIsDefined then // paranoid check
      EHttpServer.RaiseUtf8('%.Execute: %.Bind failed', [self, fSock]);
    // main ACCEPT loop
    while not Terminated do
    begin
      res := Sock.Sock.Accept(cltsock, cltaddr, {async=}false);
      if not (res in [nrOK, nrRetry]) then
      begin
        if Terminated then
          break;
        SleepHiRes(1); // failure (too many clients?) -> wait and retry
        continue;
      end;
      if Terminated or
         (Sock = nil) then
      begin
        if res = nrOk then
          cltsock.ShutdownAndClose({rdwr=}true);
        break; // don't accept input if server is down, and end thread now
      end;
      tix64 := 0;
      if Assigned(fBanned) and
         {$ifdef OSPOSIX}
         (res = nrRetry) and // Windows does not implement timeout on accept()
         {$endif OSPOSIX}
         (fBanned.Count <> 0) then
      begin
        // call fBanned.DoRotate exactly every second
        tix64 := mormot.core.os.GetTickCount64;
        sec := tix64 div 1000;
        if bansec <> 0 then
          for i := bansec + 1 to sec do // as many DoRotate as elapsed seconds
            fBanned.DoRotate // update internal THttpAcceptBan lists
        {$ifdef OSPOSIX} // Windows would require some activity - not an issue
        else
          fSock.ReceiveTimeout := 1000 // accept() to exit after one second
        {$endif OSPOSIX};
        bansec := sec;
      end;
      if res = nrRetry then // accept() timeout after 1 or 5 seconds
      begin
        if tix64 = 0 then
          tix64 := mormot.core.os.GetTickCount64;
        if Assigned(fOnAcceptIdle) then
          fOnAcceptIdle(self, tix64); // e.g. TAcmeLetsEncryptServer.OnAcceptIdle
        if Assigned(fLogger) then
          fLogger.OnIdle(tix64) // flush log file(s) on idle server
        else if Assigned(fAnalyzer) then
          fAnalyzer.OnIdle(tix64); // consolidate telemetry if needed
        continue;
      end;
      if fBanned.IsBanned(cltaddr) then // IP filtering from blacklist
      begin
        banlen := ord(HTTP_BANIP_RESPONSE[0]);
        cltsock.Send(@HTTP_BANIP_RESPONSE[1], banlen); // 418 I'm a teapot
        cltsock.ShutdownAndClose({rdwr=}false);
        continue; // abort even before TLS or HTTP start
      end;
      OnConnect;
      if fMonoThread then
        // ServerThreadPoolCount < 0 would use a single thread to rule them all
        // - may be defined when the server is expected to have very low usage,
        // e.g. for port 80 to 443 redirection or to implement Let's Encrypt
        // HTTP-01 challenges (on port 80) using OnHeaderParsed callback
        try
          cltservsock := fSocketClass.Create(self);
          try
            cltservsock.AcceptRequest(cltsock, @cltaddr);
            if hsoEnableTls in fOptions then
              cltservsock.DoTlsAfter(cstaAccept);
            case cltservsock.GetRequest({withbody=}true, HeaderRetrieveAbortTix) of
              grBodyReceived,
              grHeaderReceived:
                begin
                  include(cltservsock.Http.HeaderFlags, hfConnectionClose);
                  Process(cltservsock, 0, self);
                end;
              grClosed,      // e.g. gracefully disconnected
              grIntercepted: // handled by OnHeaderParsed event -> no ban
                ;
            else
              if fBanned.BanIP(cltaddr.IP4) then // e.g. after grTimeout
                IncStat(grBanned);
            end;
            OnDisconnect;
          finally
            cltservsock.Free;
          end;
        except
          on E: Exception do
            // do not stop thread on TLS or socket error
            if Assigned(fSock.OnLog) then
              fSock.OnLog(sllTrace, 'Execute: % [%]', [E, E.Message], self);
        end
      else if Assigned(fThreadPool) then
      begin
        // ServerThreadPoolCount > 0 will use the thread pool to process the
        // request header, and probably its body unless kept-alive or upgraded
        // - this is the most efficient way of using this server class
        cltservsock := fSocketClass.Create(self);
        // note: we tried to reuse the fSocketClass instance -> no perf benefit
        cltservsock.AcceptRequest(cltsock, @cltaddr);
        if not fThreadPool.Push(pointer(cltservsock), {waitoncontention=}true) then
          // was false if there is no idle thread in the pool, and queue is full
          cltservsock.Free; // will call DirectShutdown(cltsock)
      end
      else
        // ServerThreadPoolCount = 0 is a (somewhat resource hungry) fallback
        // implementation with one thread for each incoming socket
        fThreadRespClass.Create(cltsock, cltaddr, self);
    end;
  except
    on E: Exception do
      // any exception would break and release the thread
      FormatUtf8('% [%]', [E, E.Message], fExecuteMessage);
  end;
  fSafe.Lock;
  fExecuteState := esFinished;
  fSafe.UnLock;
end;

procedure THttpServer.OnConnect;
begin
  LockedInc32(@fServerConnectionCount);
  LockedInc32(@fServerConnectionActive);
end;

procedure THttpServer.OnDisconnect;
begin
  LockedDec32(@fServerConnectionActive);
end;

const
  STATICFILE_PROGWAITMS = 10; // up to 16ms on Windows

procedure THttpServer.Process(ClientSock: THttpServerSocket;
  ConnectionID: THttpServerConnectionID; ConnectionThread: TSynThread);
var
  req: THttpServerRequest;
  output: PRawByteStringBuffer;
  dest: TRawByteStringBuffer;
  started: Int64;
  ctx: TOnHttpServerAfterResponseContext;
begin
  if (ClientSock = nil) or
     (ClientSock.Http.Headers = '') or
     Terminated then
    // we didn't get the request = socket read error
    exit; // -> send will probably fail -> nothing to send back
  // compute and send back the response
  if Assigned(fOnAfterResponse) then
    QueryPerformanceMicroSeconds(started);
  req := THttpServerRequest.Create(self, ConnectionID, ConnectionThread, 0,
    ClientSock.fRequestFlags, ClientSock.GetConnectionOpaque);
  try
    // compute the response
    req.Prepare(ClientSock.Http, ClientSock.fRemoteIP, fAuthorize);
    DoRequest(req);
    output := req.SetupResponse(
      ClientSock.Http, fCompressGz, fServerSendBufferSize);
    if fBanned.ShouldBan(req.RespStatus, ClientSock.fRemoteIP) then
      IncStat(grBanned);
    // send back the response
    if Terminated then
      exit;
    if hfConnectionClose in ClientSock.Http.HeaderFlags then
      ClientSock.fKeepAliveClient := false;
    if ClientSock.TrySndLow(output.Buffer, output.Len) then // header[+body]
      while not Terminated do
      begin
        case ClientSock.Http.State of
          hrsResponseDone:
            break; // finished (set e.g. by ClientSock.Http.ProcessBody)
          hrsSendBody:
            begin
              dest.Reset; // body is retrieved from Content/ContentStream
              case ClientSock.Http.ProcessBody(dest, fServerSendBufferSize) of
                hrpSend:
                  if ClientSock.TrySndLow(dest.Buffer, dest.Len) then
                    continue;
                hrpWait:
                  begin
                    SleepHiRes(STATICFILE_PROGWAITMS);
                    continue; // wait until got some data
                  end;
                hrpDone:
                  break;
              else // hrpAbort:
                if Assigned(ClientSock.OnLog) then
                  ClientSock.OnLog(sllWarning,
                    'Process: ProcessBody aborted (ProgressiveID=%)',
                    [ClientSock.Http.ProgressiveID], self);
              end;
            end;
        end;
        ClientSock.fKeepAliveClient := false; // socket close on write error
        break;
      end
    else
      ClientSock.fKeepAliveClient := false;
    // the response has been sent: handle optional OnAfterResponse event
    if Assigned(fOnAfterResponse) then
    try
      QueryPerformanceMicroSeconds(ctx.ElapsedMicroSec);
      dec(ctx.ElapsedMicroSec, started);
      ctx.Connection := req.ConnectionID;
      ctx.User := pointer(req.AuthenticatedUser);
      ctx.Method := pointer(req.Method);
      ctx.Host := pointer(req.Host);
      ctx.Url := pointer(req.Url);
      ctx.Referer := pointer(ClientSock.Http.Referer);
      ctx.UserAgent := pointer(req.UserAgent);
      ctx.RemoteIP := pointer(req.RemoteIP);
      ctx.Flags := req.ConnectionFlags;
      ctx.State := ClientSock.Http.State;
      ctx.StatusCode := req.RespStatus;
      ctx.Tix64 := 0;
      ctx.Received := ClientSock.BytesIn;
      ctx.Sent := ClientSock.BytesOut;
      fOnAfterResponse(ctx); // e.g. THttpLogger or THttpAnalyzer
    except
      on E: Exception do // paranoid
      begin
        fOnAfterResponse := nil; // won't try again
        if Assigned(ClientSock.OnLog) then
          ClientSock.OnLog(sllWarning,
            'Process: OnAfterResponse raised % -> disabled', [E], self);
      end;
    end;
  finally
    req.Free;
    if Assigned(fOnProgressiveRequestFree) then
      DoProgressiveRequestFree(ClientSock.Http); // e.g. THttpPartials.Remove
    ClientSock.Http.ProcessDone;   // ContentStream.Free
  end;
  // add transfert stats to main socket
  if Sock <> nil then
  begin
    fSafe.Lock;
    Sock.BytesIn := Sock.BytesIn + ClientSock.BytesIn;
    Sock.BytesOut := Sock.BytesOut + ClientSock.BytesOut;
    fSafe.UnLock;
  end;
  ClientSock.fBytesIn := 0;
  ClientSock.fBytesOut := 0;
end;


{ THttpServerSocket }

procedure THttpServerSocket.TaskProcess(aCaller: TSynThreadPoolWorkThread);
var
  freeme: boolean;
  res: THttpServerSocketGetRequestResult;
begin
  // process this THttpServerSocket request in the thread pool
  freeme := true;
  try
    // (slow) TLS handshake is done in this sub-thread
    if (hsoEnableTls in fServer.Options) and
       (fSecure = nil) then
      DoTlsAfter(cstaAccept);
    // get and validate the headers of this first request
    res := GetRequest({withbody=}false, fServer.HeaderRetrieveAbortTix);
    // process any auth steps, then body in this thread or in a fThreadRespClass
    freeme := TaskProcessBody(aCaller, res);
  finally
    if freeme then // false if kept-alive in a fThreadRespClass thread
      Free;
  end;
end;

function THttpServerSocket.TaskProcessBody(aCaller: TSynThreadPoolWorkThread;
  aHeaderResult: THttpServerSocketGetRequestResult): boolean;
var
  pool: TSynThreadPoolTHttpServer;
begin
  result := true; // freeme = true by default
  if (fServer = nil) or
     fServer.Terminated  then
    exit;
  // properly get the incoming body and process the request
  repeat
    fServer.IncStat(aHeaderResult);
    case aHeaderResult of
      grHeaderReceived:
        begin
          pool := TSynThreadPoolTHttpServer(aCaller.Owner);
          // connection and header seem valid -> process request further
          if (fServer.ServerKeepAliveTimeOut > 0) and
             (fServer.fInternalHttpServerRespList.Count < pool.MaxBodyThreadCount) and
             (KeepAliveClient or
              (Http.ContentLength > pool.BigBodySize)) then
          begin
            // HTTP/1.1 Keep Alive (including WebSockets) or posted data > 16 MB
            // -> process in dedicated background thread
            fServer.fThreadRespClass.Create(self, fServer);
            result := false; // freeme=false: THttpServerResp will own self
          end
          else
          begin
            // no Keep Alive = multi-connection -> process in the Thread Pool
            if not (hfConnectionUpgrade in Http.HeaderFlags) and
               not HttpMethodWithNoBody(Method) then
            begin
              GetBody; // we need to get it now
              fServer.IncStat(grBodyReceived);
            end;
            // multi-connection -> process now
            fServer.Process(self, fRemoteConnectionID, aCaller);
            fServer.OnDisconnect;
            // no Shutdown here: will be done client-side
          end;
        end;
      grIntercepted:
        ; // response was sent by OnHeaderParsed()
      grWwwAuthenticate:
        // return 401 and wait for the "Authorize:" answer in the thread pool
        aHeaderResult := GetRequest(false, fServer.HeaderRetrieveAbortTix);
    else
      begin
        if Assigned(fServer.Sock.OnLog) then
          fServer.Sock.OnLog(sllTrace, 'Task: close after GetRequest=% from %',
              [ToText(aHeaderResult)^, fRemoteIP], self);
        if (aHeaderResult <> grClosed) and
           fServer.fBanned.BanIP(fRemoteIP) then
          fServer.IncStat(grBanned);
      end;
    end;
  until aHeaderResult <> grWwwAuthenticate; // continue handshake in this thread
end;

constructor THttpServerSocket.Create(aServer: THttpServer);
begin
  inherited Create(5000);
  if aServer <> nil then // nil e.g. from TRtspOverHttpServer
  begin
    fServer := aServer;
    Http.Compress := aServer.fCompress;
    Http.CompressAcceptEncoding := aServer.fCompressAcceptEncoding;
    fSocketLayer := aServer.Sock.SocketLayer;
    if hsoEnableTls in aServer.fOptions then
    begin
      if not aServer.fSock.TLS.Enabled then // if not already in WaitStarted()
        aServer.InitializeTlsAfterBind;     // load certificate(s) once
      TLS.AcceptCert := aServer.Sock.TLS.AcceptCert; // TaskProcess cstaAccept
    end;
    OnLog := aServer.Sock.OnLog;
  end;
end;

function THttpServerSocket.GetRequest(withBody: boolean;
  headerMaxTix: Int64): THttpServerSocketGetRequestResult;
var
  P: PUtf8Char;
  status, tix32: cardinal;
  noheaderfilter, http10: boolean;
begin
  try
    // use SockIn with 1KB buffer if not already initialized: 2x faster
    CreateSockIn;
    // abort now with no exception if socket is obviously broken
    result := grClosed;
    if fServer <> nil then
    begin
      if (SockInPending(100) < 0) or
         (fServer = nil) or
         fServer.Terminated then
        exit;
      noheaderfilter := hsoHeadersUnfiltered in fServer.Options;
    end
    else
      noheaderfilter := false;
    // 1st line is command: 'GET /path HTTP/1.1' e.g.
    SockRecvLn(Http.CommandResp);
    P := pointer(Http.CommandResp);
    if P = nil then
      exit; // connection is likely to be broken or closed
    GetNextItem(P, ' ', Http.CommandMethod); // 'GET'
    GetNextItem(P, ' ', Http.CommandUri);    // '/path'
    result := grRejected;
    if PCardinal(P)^ <>
         ord('H') + ord('T') shl 8 + ord('T') shl 16 + ord('P') shl 24 then
      exit;
    http10 := P[7] = '0';
    fKeepAliveClient := ((fServer = nil) or
                         (fServer.ServerKeepAliveTimeOut > 0)) and
                        not http10;
    Http.Content := '';
    // get and parse HTTP request header
    if not GetHeader(noheaderfilter) then
    begin
      SockSendFlush('HTTP/1.0 400 Bad Request'#13#10 +
        'Content-Length: 16'#13#10#13#10'Rejected Headers');
      exit;
    end;
    fServer.ParseRemoteIPConnID(Http.Headers, fRemoteIP, fRemoteConnectionID);
    if hfConnectionClose in Http.HeaderFlags then
      fKeepAliveClient := false;
    if (Http.ContentLength < 0) and
       (KeepAliveClient or
        IsGet(Http.CommandMethod)) then
      Http.ContentLength := 0; // HTTP/1.1 and no content length -> no eof
    if (headerMaxTix > 0) and
       (mormot.core.os.GetTickCount64 > headerMaxTix) then
    begin
      result := grTimeout;
      exit; // allow 10 sec for header -> DOS/TCPSYN Flood
    end;
    if fServer <> nil then
    begin
      // allow THttpServer.OnHeaderParsed low-level callback
      if Assigned(fServer.fOnHeaderParsed) then
      begin
        result := fServer.fOnHeaderParsed(self);
        if result <> grHeaderReceived then
          exit; // the callback made its own SockSend() response
      end;
      // validate allowed PayLoad size
      if (Http.ContentLength > 0) and
         (fServer.MaximumAllowedContentLength > 0) and
         (Http.ContentLength > fServer.MaximumAllowedContentLength) then
      begin
        // 413 HTTP error (and close connection)
        fServer.SetRejectInCommandUri(Http, 0, HTTP_PAYLOADTOOLARGE);
        SockSendFlush(Http.CommandUri);
        result := grOversizedPayload;
        exit;
      end;
      // support optional Basic/Digest authentication
      fRequestFlags := HTTP_TLS_FLAGS[TLS.Enabled] +
                       HTTP_UPG_FLAGS[hfConnectionUpgrade in Http.HeaderFlags] +
                       HTTP_10_FLAGS[http10];
      if (hfHasAuthorization in Http.HeaderFlags) and
         (fServer.fAuthorize <> hraNone) then
      begin
        if fServer.Authorization(Http, fRemoteConnectionID) = asrMatch then
        begin
          fAuthorized := fServer.fAuthorize;
          include(fRequestFlags, hsrAuthorized);
        end
        else
        begin
          tix32 := mormot.core.os.GetTickCount64 shr 12;
          if fAuthSec = tix32 then
          begin
            // 403 HTTP error if not authorized (and close connection)
            fServer.SetRejectInCommandUri(Http, 0, HTTP_FORBIDDEN);
            SockSendFlush(Http.CommandUri);
            result := grRejected;
            exit;
          end
          else
            // 401 HTTP error to ask for credentials and renew after 4 seconds
            // (ConnectionID may have changed in-between)
            fAuthSec := tix32;
        end;
      end;
      // allow OnBeforeBody callback for quick response
      if Assigned(fServer.OnBeforeBody) then
      begin
        HeadersPrepare(fRemoteIP); // will include remote IP to Http.Headers
        status := fServer.OnBeforeBody(Http.CommandUri, Http.CommandMethod,
          Http.Headers, Http.ContentType, fRemoteIP, Http.BearerToken,
          Http.ContentLength, fRequestFlags);
        {$ifdef SYNCRTDEBUGLOW}
        TSynLog.Add.Log(sllCustom2,
          'GetRequest sock=% OnBeforeBody=% Command=% Headers=%', [fSock, status,
          LogEscapeFull(Command), LogEscapeFull(allheaders)], self);
        {$endif SYNCRTDEBUGLOW}
        if status <> HTTP_SUCCESS then
        begin
          if fServer.SetRejectInCommandUri(Http, fRemoteConnectionID, status) then
            result := grWwwAuthenticate
          else
            result := grRejected;
          SockSendFlush(Http.CommandUri);
          exit;
        end;
      end;
    end;
    // implement 'Expect: 100-Continue' Header
    if hfExpect100 in Http.HeaderFlags then
      // client waits for the server to parse the headers and return 100
      // before sending the request body
      SockSendFlush('HTTP/1.1 100 Continue'#13#10#13#10);
    // now the server could retrieve the HTTP request body
    if withBody and
       not (hfConnectionUpgrade in Http.HeaderFlags) then
    begin
      if not HttpMethodWithNoBody(Http.CommandMethod) then
        GetBody;
      result := grBodyReceived;
    end
    else
      result := grHeaderReceived;
  except
    on E: Exception do
      result := grException;
  end;
end;

function THttpServerSocket.GetConnectionOpaque: PHttpServerConnectionOpaque;
begin
  if (fServer = nil) or
     (fServer.fRemoteConnIDHeaderUpper = '') then
    result := @fConnectionOpaque
  else
    result := nil // "opaque" is clearly unsupported behind a proxy
end;


{ THttpServerResp }

constructor THttpServerResp.Create(aSock: TNetSocket; const aSin: TNetAddr;
  aServer: THttpServer);
var
  c: THttpServerSocketClass;
begin
  fClientSock := aSock;
  fClientSin := aSin;
  if aServer = nil then
    c := THttpServerSocket
  else
    c := aServer.fSocketClass;
  Create(c.Create(aServer), aServer); // on Linux, Execute raises during Create
end;

constructor THttpServerResp.Create(aServerSock: THttpServerSocket;
  aServer: THttpServer);
begin
  fServer := aServer;
  fServerSock := aServerSock;
  fOnThreadTerminate := fServer.fOnThreadTerminate;
  fServer.fInternalHttpServerRespList.Add(self);
  fConnectionID := aServerSock.fRemoteConnectionID;
  FreeOnTerminate := true;
  inherited Create(false);
end;

procedure THttpServerResp.Shutdown;
begin
  Terminate;
  if fServerSock <> nil then
    fServerSock.Close;
end;

procedure THttpServerResp.Execute;

  procedure HandleRequestsProcess;
  var
    keepaliveendtix, beforetix, headertix, tix: Int64;
    pending: TCrtSocketPending;
    res: THttpServerSocketGetRequestResult;
    banned: boolean;
  begin
    {$ifdef SYNCRTDEBUGLOW}
    try
    {$endif SYNCRTDEBUGLOW}
    try
      repeat
        beforetix := mormot.core.os.GetTickCount64;
        keepaliveendtix := beforetix + fServer.ServerKeepAliveTimeOut;
        repeat
          // within this loop, break=wait for next command, exit=quit
          if (fServer = nil) or
             fServer.Terminated or
             (fServerSock = nil) then
            // server is down -> close connection
            exit;
          pending := fServerSock.SockReceivePending(50); // 50 ms timeout
          if (fServer = nil) or
             fServer.Terminated then
            // server is down -> disconnect the client
            exit;
          {$ifdef SYNCRTDEBUGLOW}
          TSynLog.Add.Log(sllCustom2, 'HandleRequestsProcess: sock=% pending=%',
            [fServerSock.fSock, _CSP[pending]], self);
          {$endif SYNCRTDEBUGLOW}
          case pending of
            cspSocketError,
            cspSocketClosed:
              begin
                if Assigned(fServer.Sock.OnLog) then
                  fServer.Sock.OnLog(sllTrace, 'Execute: Socket error from %',
                    [fServerSock.RemoteIP], self);
                exit; // disconnect the client
              end;
            cspNoData:
              begin
                tix := mormot.core.os.GetTickCount64;
                if tix >= keepaliveendtix then
                begin
                  if Assigned(fServer.Sock.OnLog) then
                    fServer.Sock.OnLog(sllTrace, 'Execute: % KeepAlive=% timeout',
                      [fServerSock.RemoteIP, keepaliveendtix - tix], self);
                  exit; // reached keep alive time out -> close connection
                end;
                if tix - beforetix < 40 then
                begin
                  {$ifdef SYNCRTDEBUGLOW}
                  // getsockopt(fServerSock.fSock,SOL_SOCKET,SO_ERROR,@error,errorlen) returns 0 :(
                  TSynLog.Add.Log(sllCustom2,
                    'HandleRequestsProcess: sock=% LOWDELAY=%',
                    [fServerSock.fSock, tix - beforetix], self);
                  {$endif SYNCRTDEBUGLOW}
                  SleepHiRes(1); // seen only on Windows in practice
                  if (fServer = nil) or
                     fServer.Terminated then
                    // server is down -> disconnect the client
                    exit;
                end;
                beforetix := tix;
              end;
            cspDataAvailable,
            cspDataAvailableOnClosedSocket:
              begin
                // get request and headers
                headertix := fServer.HeaderRetrieveAbortDelay;
                if headertix > 0 then
                  inc(headertix, beforetix);
                res := fServerSock.GetRequest({withbody=}true, headertix);
                if (fServer = nil) or
                   fServer.Terminated then
                  // server is down -> disconnect the client
                  exit;
                if pending = cspDataAvailableOnClosedSocket then
                  fServerSock.KeepAliveClient := false; // we can't keep it
                fServer.IncStat(res);
                case res of
                  grBodyReceived,
                  grHeaderReceived:
                    begin
                      if res = grBodyReceived then
                        fServer.IncStat(grHeaderReceived);
                      // calc answer and send response
                      fServer.Process(fServerSock, ConnectionID, self);
                      // keep connection only if necessary
                      if fServerSock.KeepAliveClient then
                        break
                      else
                        exit;
                    end;
                  grWwwAuthenticate:
                    if fServerSock.KeepAliveClient then
                      break
                    else
                      exit;
                else
                  begin
                    banned := (res <> grClosed) and
                              fServer.fBanned.BanIP(fServerSock.RemoteIP);
                    if banned then
                      fServer.IncStat(grBanned);
                    if Assigned(fServer.Sock.OnLog) then
                      fServer.Sock.OnLog(sllTrace,
                        'Execute: close after GetRequest=% from % (ban=%)',
                        [ToText(res)^, fServerSock.RemoteIP, banned], self);
                    exit;
                  end;
                end;
              end;
          end;
        until false;
      until false;
    except
      on E: Exception do
        ; // any exception will silently disconnect the client
    end;
    {$ifdef SYNCRTDEBUGLOW}
    finally
      TSynLog.Add.Log(sllCustom2, 'HandleRequestsProcess: close sock=%',
        [fServerSock.fSock], self);
    end;
    {$endif SYNCRTDEBUGLOW}
  end;

var
  netsock: TNetSocket;
begin
  fServer.NotifyThreadStart(self);
  try
    try
      if fClientSock.Socket <> 0 then
      begin
        // direct call from incoming socket
        netsock := fClientSock;
        fClientSock := nil; // fServerSock owns fClientSock
        fServerSock.AcceptRequest(netsock, @fClientSin);
        if fServer <> nil then
          HandleRequestsProcess;
      end
      else
      begin
        // call from TSynThreadPoolTHttpServer -> handle first request
        if not fServerSock.fBodyRetrieved and
           not HttpMethodWithNoBody(fServerSock.Http.CommandMethod) then
          fServerSock.GetBody;
        fServer.Process(fServerSock, ConnectionID, self);
        if (fServer <> nil) and
           fServerSock.KeepAliveClient then
          HandleRequestsProcess; // process further kept alive requests
      end;
    finally
      try
        if fServer <> nil then
          try
            fServer.OnDisconnect;
            if Assigned(fOnThreadTerminate) then
              fOnThreadTerminate(self);
          finally
            fServer.fInternalHttpServerRespList.Remove(self);
            fServer := nil;
            fOnThreadTerminate := nil;
          end;
      finally
        FreeAndNilSafe(fServerSock);
        // if Destroy happens before fServerSock.GetRequest() in Execute below
        fClientSock.ShutdownAndClose({rdwr=}false);
      end;
    end;
  except
    on Exception do
      ; // just ignore unexpected exceptions here, especially during clean-up
  end;
end;


{ TSynThreadPoolTHttpServer }

constructor TSynThreadPoolTHttpServer.Create(Server: THttpServer;
  NumberOfThreads: integer);
begin
  fServer := Server;
  fOnThreadTerminate := fServer.fOnThreadTerminate;
  fBigBodySize := THREADPOOL_BIGBODYSIZE;
  fMaxBodyThreadCount := THREADPOOL_MAXWORKTHREADS;
  inherited Create(NumberOfThreads,
    {$ifdef USE_WINIOCP} INVALID_HANDLE_VALUE {$else} {queuepending=}true{$endif},
    Server.ProcessName);
end;

{$ifndef USE_WINIOCP}
function TSynThreadPoolTHttpServer.QueueLength: integer;
begin
  if fServer = nil then
    result := 10000
  else
    result := fServer.fHttpQueueLength;
end;
{$endif USE_WINIOCP}

procedure TSynThreadPoolTHttpServer.Task(
  aCaller: TSynThreadPoolWorkThread; aContext: pointer);
begin
  // process this THttpServerSocket in the thread pool
  if (fServer = nil) or
     fServer.Terminated then
    THttpServerSocket(aContext).Free
  else
    THttpServerSocket(aContext).TaskProcess(aCaller);
end;

procedure TSynThreadPoolTHttpServer.TaskAbort(aContext: pointer);
begin
  THttpServerSocket(aContext).Free;
end;


function ToText(res: THttpServerSocketGetRequestResult): PShortString;
begin
  result := GetEnumName(TypeInfo(THttpServerSocketGetRequestResult), ord(res));
end;




{ ******************** THttpPeerCache Local Peer-to-peer Cache }

{ THttpPeerCrypt }

procedure THttpPeerCrypt.AfterSettings;
var
  err: RawUtf8;
begin
  if fSettings = nil then
    EHttpPeerCache.RaiseUtf8('%.AfterSettings(nil)', [self]);
  fLog.Add.Log(sllTrace, 'Create: with %', [fSettings], self);
  err := fSettings.GuessInterface(fMac);
  if err <> '' then
    EHttpPeerCache.RaiseUtf8('%.Create: %', [self, err]);
  IPToCardinal(fMac.IP, fIP4);
  IPToCardinal(fMac.NetMask, fMaskIP4);
  IPToCardinal(fMac.Broadcast, fBroadcastIP4);
  UInt32ToUtf8(fSettings.Port, fPort);
  FormatUtf8('%:%', [fMac.IP, fPort], fIpPort); // UDP/TCP bound to this network
  if fSettings.RejectInstablePeersMin > 0 then
  begin
    fInstable := THttpAcceptBan.Create(fSettings.RejectInstablePeersMin);
    fInstable.WhiteIP := fIP4; // from localhost: only hsoBan40xIP (4 seconds)
  end;
  fLog.Add.Log(sllDebug, 'Create: network="%" as % (broadcast=%) %',
    [fMac.Name, fIpPort, fMac.Broadcast, fMac.Address], self);
end;

function THttpPeerCrypt.GetUuidText: RawUtf8;
begin
  ToUtf8(fUuid, result);
end;

function THttpPeerCrypt.CurrentConnections: integer;
begin
  result := 0; // to be properly overriden with the HTTP server information
end;

procedure THttpPeerCrypt.MessageInit(aKind: THttpPeerCacheMessageKind;
  aSeq: cardinal; out aMsg: THttpPeerCacheMessage);
var
  n: cardinal;
begin
  FillCharFast(aMsg, SizeOf(aMsg) - SizeOf(aMsg.Padding), 0);
  RandomBytes(@aMsg.Padding, SizeOf(aMsg.Padding)); // Lecuyer is enough
  if aSeq = 0 then
    aSeq := InterlockedIncrement(fFrameSeq);
  aMsg.Seq := aSeq;
  aMsg.Kind := aKind;
  aMsg.Uuid := fUuid;
  aMsg.Os := OSVersion32;
  aMsg.IP4 := fIP4;
  aMsg.DestIP4 := fBroadcastIP4; // overriden in DoSendResponse()
  aMsg.MaskIP4 := fMaskIP4;
  aMsg.BroadcastIP4 := fBroadcastIP4;
  aMsg.Speed := fMac.Speed;
  aMsg.Hardware := fMac.Kind;
  aMsg.Timestamp := UnixTimeMinimalUtc;
  n := CurrentConnections; // virtual method
  if n > 65535 then
    n := 65535;
  aMsg.Connections := n;
end;

// UDP frames are AES-GCM encrypted and signed, ending with a 32-bit crc, fixed
// to crc32c(): md5/sha (without SHA-NI) are slower than AES-GCM-128 itself ;)
// - on x86_64 THttpPeerCache: 14,003 assertions passed  17.39ms
//   2000 messages in 413us i.e. 4.6M/s, aver. 206ns, 886.7 MB/s  = AES-GCM-128
//   10000 altered in 135us i.e. 70.6M/s, aver. 13ns, 13.2 GB/s   = crc32c()

function THttpPeerCrypt.MessageEncode(const aMsg: THttpPeerCacheMessage): RawByteString;
var
  tmp: RawByteString;
  p: PAnsiChar;
  l: PtrInt;
begin
  // AES-GCM-128 encoding and authentication
  FastSetRawByteString(tmp, @aMsg, SizeOf(aMsg));
  fAesSafe.Lock;
  try
    result := fAesEnc.MacAndCrypt(tmp, {enc=}true, {iv=}true, '', {endsize=}4);
  finally
    fAesSafe.UnLock;
  end;
  // append salted checksum to quickly reject any fuzzing attempt (endsize=4)
  p := pointer(result);
  l := length(result) - 4;
  PCardinal(p + l)^ := crc32c(fSharedMagic, p, l);
end;

function THttpPeerCrypt.MessageDecode(aFrame: PAnsiChar; aFrameLen: PtrInt;
  out aMsg: THttpPeerCacheMessage): THttpPeerCryptMessageDecode;

  function DoDecode: THttpPeerCryptMessageDecode;
  var // sub-function to avoid any hidden try..finally
    encoded, plain: RawByteString;
  begin
    // AES-GCM-128 decoding and authentication
    FastSetRawByteString(encoded, aFrame, aFrameLen);
    fAesSafe.Lock;
    try
      plain := fAesDec.MacAndCrypt(encoded, {enc=}false, {iv=}true);
    finally
      fAesSafe.UnLock;
    end;
    // check consistency of the decoded THttpPeerCacheMessage value
    result := mdAes;
    if length(plain) <> SizeOf(aMsg) then
      exit;
    MoveFast(pointer(plain)^, aMsg, SizeOf(aMsg));
    result := mdSeq;
    if (aMsg.Kind in PCF_RESPONSE) and // responses are broadcasted on POSIX
       (aMsg.DestIP4 = fIP4) then     // only validate against the local sequence
      if (aMsg.Seq < fFrameSeqLow) or
         (aMsg.Seq > cardinal(fFrameSeq)) then // compare with local sequence
        exit;
    result := mdKind;
    if ord(aMsg.Kind) > ord(high(aMsg.Kind)) then
      exit;
    result := mdHw;
    if ord(aMsg.Hardware) > ord(high(aMsg.Hardware)) then
      exit;
    result := mdAlgo;
    if ord(aMsg.Hash.Algo) > ord(high(aMsg.Hash.Algo)) then
      exit;
    result := mdOk;
  end;

begin
  // quickly reject any naive fuzzing attempt
  result := mdLen;
  dec(aFrameLen, 4);
  if aFrameLen < SizeOf(aMsg) + SizeOf(TAesBlock) * 2 {iv+padding} then
    exit;
  result := mdCrc;
  if PCardinal(aFrame + aFrameLen)^ = crc32c(fSharedMagic, aFrame, aFrameLen) then
    // decode and verify the frame content
    result := DoDecode;
end;

function THttpPeerCrypt.BearerDecode(
  const aBearerToken: RawUtf8; aExpected: THttpPeerCacheMessageKind;
  out aMsg: THttpPeerCacheMessage): THttpPeerCryptMessageDecode;
var
  tok: array[0.. 511] of AnsiChar; // no memory allocation
  bearerlen, toklen: PtrInt;
begin
  bearerlen := length(aBearerToken);
  toklen := Base64uriToBinLength(bearerlen);
  result := mdBLen;
  if toklen > SizeOf(tok) then
    exit;
  result := mdB64;
  if not Base64uriToBin(pointer(aBearerToken), @tok, bearerlen, toklen) then
    exit;
  result := MessageDecode(@tok, toklen, aMsg);
  if (result = mdOk) and
     (aExpected >= pcfBearer) and
     (aMsg.Kind <> aExpected) then
    result := mdBearer;
end;

function THttpPeerCrypt.LocalPeerRequest(const aRequest: THttpPeerCacheMessage;
  var aResp : THttpPeerCacheMessage; const aUrl: RawUtf8;
  aOutStream: TStreamRedirect; aRetry: boolean): integer;
var
  tls: boolean;
  head, ip: RawUtf8;

  procedure LocalPeerRequestFailed(E: TClass);
  begin
    fLog.Add.Log(sllWarning, 'OnDownload: request %:% % failed as % %',
      [ip, fPort, aUrl, StatusCodeToShort(result), E], self);
    if (fInstable <> nil) and // add to RejectInstablePeersMin list
       not aRetry then        // not from partial request before broadcast
      fInstable.BanIP(aResp.IP4); // this peer may have a HTTP firewall issue
    FreeAndNil(fClient);
    fClientIP4 := 0;
    result := 0; // will fallback to regular GET on the main repository
  end;

begin
  result := 0;
  try
    // compute the call parameters and the request bearer
    IP4Text(@aResp.IP4, ip);
    fLog.Add.Log(sllDebug, 'OnDownload: request %:% %', [ip, fPort, aUrl], self);
    aResp.Kind := pcfBearer; // authorize OnBeforeBody with response message
    head := AuthorizationBearer(BinToBase64uri(MessageEncode(aResp)));
    // ensure we have the right peer
    if (fClient <> nil) and
       (fClientIP4 <> aResp.IP4) then
      FreeAndNil(fClient);
    // ensure we have the expected HTTP/HTTPS connection
    if fClient = nil then
    begin
      fClient := THttpClientSocket.Create(fSettings.HttpTimeoutMS);
      tls := fClientTls.Enabled or
             (pcoSelfSignedHttps in fSettings.Options);
      if tls then
        if fClientTls.Enabled then
          fClient.TLS := fClientTls
        else
          fClient.TLS.IgnoreCertificateErrors := true; // self-signed
      fClient.OpenBind(ip, fPort, {bind=}false, tls);
      fClient.ReceiveTimeout := 5000; // once connected, 5 seconds timeout
      fClient.OnLog := fLog.DoLog;
    end;
    // makes the GET request, optionally with the needed range bytes
    fClient.RangeStart := aRequest.RangeStart;
    fClient.RangeEnd   := aRequest.RangeEnd;
    if fSettings.LimitMBPerSec >= 0 then // -1 to keep original value
      aOutStream.LimitPerSecond := fSettings.LimitMBPerSec shl 20; // bytes/sec
    result := fClient.Request(
      aUrl, 'GET', 30000, head, '',  '', aRetry, nil, aOutStream);
    fLog.Add.Log(sllTrace, 'OnDownload: request=%', [result], self);
    if result in HTTP_GET_OK then
      fClientIP4 := aResp.IP4 // success or not found (HTTP_NOCONTENT)
    else
      LocalPeerRequestFailed(nil); // error downloading from local peer
  except
    on E: Exception do
      LocalPeerRequestFailed(PClass(E)^);
  end;
end;

constructor THttpPeerCrypt.Create(const aSharedSecret: RawByteString;
  aServerTls, aClientTls: PNetTlsContext);
var
  key: THash256Rec;
begin
  // setup internal processing status
  fFrameSeqLow := Random31Not0; // 31-bit random start value set at startup
  fFrameSeq := fFrameSeqLow;
  // setup internal cryptography
  if aSharedSecret = '' then
    EHttpPeerCache.RaiseUtf8('%.Create without aSharedSecret', [self]);
  HmacSha256('4b0fb62af680447c9d0604fc74b908fa', aSharedSecret, key.b);
  fAesEnc := TAesFast[mGCM].Create(key.Lo) as TAesGcmAbstract; // lower 128-bit
  fAesDec := fAesEnc.Clone as TAesGcmAbstract; // two AES-GCM-128 instances
  HmacSha256(key.b, '2b6f48c3ffe847b9beb6d8de602c9f25', key.b); // paranoid
  fSharedMagic := key.h.c3; // 32-bit derivation for anti-fuzzing checksum
  if Assigned(fLog) then
    // log includes safe 16-bit key.w[0] fingerprint
    fLog.Add.Log(sllTrace, 'Create: Uuid=% SecretFingerPrint=%, Seq=#%',
      [GuidToShort(fUuid), key.w[0], CardinalToHexShort(fFrameSeq)], self);
  FillZero(key.b);
  if aServerTls <> nil then
    fServerTls := aServerTls^;
  if aClientTls <> nil then
    fClientTls := aClientTls^;
end;

destructor THttpPeerCrypt.Destroy;
begin
  FreeAndNilSafe(fClient);
  FreeAndNil(fInstable);
  FreeAndNil(fAesEnc);
  FreeAndNil(fAesDec);
  fSharedMagic := 0;
  inherited Destroy;
end;

function THttpPeerCrypt.NetworkInterfaceChanged: boolean;
var
  newmac: TMacAddress;
  err: RawUtf8;
  tix: cardinal;
begin
  result := false;
  if self = nil then
    exit;
  tix := GetTickCount64 shr 10; // calling OS API every second is good enough
  if tix = fLastNetworkTix then
    exit;
  fLastNetworkTix := tix;
  MacIPAddressFlush; // flush mormot.net.sock cache
  err := fSettings.GuessInterface(newmac);
  result := (err = '') and
            ((fMac.Name <> newmac.Name) or
             (fMac.IP <> newmac.IP) or
             (fMac.Broadcast <> newmac.Broadcast) or
             (fMac.NetMask <> newmac.NetMask));
  if Assigned(fLog) then
    fLog.Add.Log(sllTrace, 'NetworkInterfaceChanged=% [% % % %] %',
      [BOOL_STR[result], newmac.Name, newmac.IP, newmac.Broadcast, newmac.NetMask, err], self);
end;

const
  DIRECTURI_32 = ord('/') + ord('h') shl 8 + ord('t') shl 16 + ord('t') shl 24;

class function THttpPeerCrypt.HttpDirectUri(const aSharedSecret: RawByteString;
  const aRemoteUri, aRemoteHash: RawUtf8;
  out aDirectUri, aDirectHeaderBearer: RawUtf8): boolean;
var
  c: THttpPeerCrypt;
  msg: THttpPeerCacheMessage;
  p: RawUtf8;
  uri: TUri;
begin
  result := false;
  if (aSharedSecret = '') or
     (aRemoteHash = '') or
     not uri.From(aRemoteUri) then
    exit;
  c := THttpPeerCrypt.Create(aSharedSecret, nil, nil);
  try
    c.MessageInit(pcfBearerDirect, 0, msg);
    if not HashDetect(aRemoteHash, msg.Hash) then
      exit;
    if uri.Port <> DEFAULT_PORT[uri.Https] then
      p := NetConcat(['_', uri.Port]); // '_' is ok for URI, but not for domain
    FormatUtf8('/%/%%/%', [uri.Scheme, uri.Server, p, uri.Address], aDirectUri);
    msg.Opaque := crc63c(pointer(aDirectUri), length(aDirectUri)); // no replay
    aDirectHeaderBearer := AuthorizationBearer(BinToBase64uri(c.MessageEncode(msg)));
    result := true;
  finally
    c.Free;
  end;
end;

class function THttpPeerCrypt.HttpDirectUriReconstruct(P: PUtf8Char;
  out Decoded: TUri): boolean;
var
  scheme, domain: RawUtf8;
begin
  result := false;
  if (P = nil) or
     (PCardinal(P)^ <> DIRECTURI_32) then
    exit;
  inc(P); // http/... or https/...
  GetNextItem(P, '/', scheme);
  GetNextItem(P, '/', domain); // domain/... or domain_port/...
  domain := StringReplaceChars(domain, '_', ':');
  if (domain <> '') and
     (P <> nil) then
    result := Decoded.From(Make([scheme, '://', domain, '/', P]));
end;


{ THttpPeerCacheSettings }

constructor THttpPeerCacheSettings.Create;
begin
  inherited Create;
  fPort := 8099;
  fLimitMBPerSec := 10;
  fLimitClientCount := 32;
  fRejectInstablePeersMin := 4;
  fCacheTempPath := '*';
  fCacheTempMinBytes := 2048;
  fCacheTempMaxMB := 1000;
  fCacheTempMaxMin := 60;
  fCachePermPath := '*';
  fCachePermMinBytes := 2048;
  fBroadcastTimeoutMS := 10;
  fBroadcastMaxResponses := 24;
  fTryAllPeersCount := 10;
  fHttpTimeoutMS := 500;
end;

function THttpPeerCacheSettings.GuessInterface(out Mac: TMacAddress): RawUtf8;
begin
  result := '';
  if fInterfaceName <> '' then
  begin
    if not GetMainMacAddress(Mac, fInterfaceName, {UpAndDown=}true) then
      // allow to pickup "down" interfaces if name is explicit
      result := FormatUtf8('impossible to find the [%] network interface',
        [fInterfaceName]);
  end
  else if not GetMainMacAddress(Mac, [mafLocalOnly, mafRequireBroadcast]) then
    result := 'impossible to find a local network interface';
end;

function THttpPeerCacheSettings.HttpDirectUri(
  const aSharedSecret: RawByteString; const aRemoteUri, aRemoteHash: RawUtf8;
  out aDirectUri, aDirectHeaderBearer: RawUtf8; aForceTls: boolean): boolean;
var
  mac: TMacAddress;
begin
  result := false;
  if (self = nil) or
     (aSharedSecret = '') or
     (pcoNoServer in fOptions) or
     (GuessInterface(mac) <> '') or
     not THttpPeerCrypt.HttpDirectUri(aSharedSecret, aRemoteUri, aRemoteHash,
           aDirectUri, aDirectHeaderBearer) then
    exit;
  aForceTls := aForceTls or (pcoSelfSignedHttps in fOptions);
  aDirectUri := Make([HTTPS_TEXT[aForceTls], mac.IP, ':', fPort, aDirectUri]);
  result := true;
end;


{ THttpPeerCacheThread }

constructor THttpPeerCacheThread.Create(Owner: THttpPeerCache);
begin
  fBroadcastSafe.Init;
  fOwner := Owner;
  fBroadcastAddr.SetIP4Port(fOwner.fBroadcastIP4, fOwner.Settings.Port);
  fBroadcastIpPort := fBroadcastAddr.IPWithPort;
  fBroadcastEvent := TSynEvent.Create;
  // POSIX requires to bind to the broadcast address to receive brodcasted frames
  inherited Create(fOwner.fLog,
    fOwner.fMac.{$ifdef OSPOSIX}Broadcast{$else}IP{$endif}, // OS-specific
    fOwner.fPort, 'udp-PeerCache', 100);
end;

destructor THttpPeerCacheThread.Destroy;
begin
  inherited Destroy;
  fBroadcastEvent.Free;
  fBroadcastSafe.Done;
end;

const
  _LATE: array[boolean] of string[7] = ('', 'late ');

procedure THttpPeerCacheThread.OnFrameReceived(len: integer;
  var remote: TNetAddr);
var
  resp: THttpPeerCacheMessage;

  procedure DoLog(const Fmt: RawUtf8; const Args: array of const);
  var
    ip, msg: shortstring;
  begin
    remote.IPShort(ip, {port=}true);
    FormatShort(Fmt, Args, msg);
    fOwner.fLog.Add.Log(sllTrace, 'OnFrameReceived: % %', [ip, msg], self)
  end;

  procedure DoSendResponse;
  var
    sock: TNetSocket;
    frame: RawByteString;
    res: TNetResult;
  begin
    // compute PCF_RESPONSE frame
    resp.DestIP4 := remote.IP4; // notify actual source IP (over broadcast)
    frame := fOwner.MessageEncode(resp);
    // respond on main UDP port and on broadcast (POSIX) or local (Windows) IP
    if fMsg.Os.os = osWindows then
      remote.SetPort(fBroadcastAddr.Port) // local IP is good enough on Windows
    else
      remote.SetIP4Port(fOwner.fBroadcastIP4, fBroadcastAddr.Port); // need to broadcast
    sock := remote.NewSocket(nlUdp);
    res := sock.SendTo(pointer(frame), length(frame), remote);
    sock.Close;
    if fOwner.fVerboseLog then
      DoLog('send=% %', [ToText(res)^, ToText(resp)]);
    inc(fSent);
  end;

var
  ok: THttpPeerCryptMessageDecode;
  late: boolean;
begin
  // quick return if this frame is not worth decoding
  if (fOwner = nil) or
     (fOwner.fSettings = nil) or     // avoid random GPF at shutdown
     (remote.IP4 = 0) or
     (remote.IP4 = fOwner.fIP4) then // Windows broadcasts to self :)
    exit;
  // RejectInstablePeersMin option: validate the input frame IP
  if fOwner.fInstable.IsBanned(remote) then
  begin
    if fOwner.fVerboseLog then
      DoLog('banned /%', [fOwner.fInstable.Count]);
    exit;
  end;
  // validate the input frame content
  ok := fOwner.MessageDecode(pointer(fFrame), len, fMsg);
  if fOwner.Check(ok, 'OnFrameReceived', fMsg) then
    if (fMsg.Kind in PCF_RESPONSE) and    // responses are broadcasted on POSIX
       (fMsg.DestIP4 <> fOwner.fIP4) then // will also detect any unexpected NAT
     begin
       if fOwner.fVerboseLog then
         DoLog('ignored % %<>%', [ToText(fMsg.Kind)^,
           IP4ToShort(@fMsg.DestIP4), IP4ToShort(@fOwner.fIP4)]);
       exit;
     end;
  late := (fMsg.Kind in PCF_RESPONSE) and
          (fMsg.Seq <> fCurrentSeq);
  if fOwner.fVerboseLog then
    if ok = mdOk then
      DoLog('%%', [_LATE[late], ToText(fMsg.Kind)^])
    else if ok <= mdAes then // decoding error
      DoLog('unexpected % len=% [%]',
        [ToText(ok)^, len, EscapeToShort(pointer(fFrame), len)]);
  // process the frame message
  if ok = mdOk then
    case fMsg.Kind of
      pcfPing:
        begin
          fOwner.MessageInit(pcfPong, fMsg.Seq, resp);
          DoSendResponse;
        end;
      pcfRequest:
        begin
          fOwner.MessageInit(pcfResponseNone, fMsg.Seq, resp);
          resp.Hash := fMsg.Hash;
          if not (pcoNoServer in fOwner.Settings.Options) then
            if integer(fOwner.fHttpServer.ConnectionsActive) >
                        fOwner.Settings.LimitClientCount then
              resp.Kind := pcfResponseOverloaded
            else if fOwner.LocalFileName(
                             fMsg, [], nil, @resp.Size) = HTTP_SUCCESS then
              resp.Kind := pcfResponseFull
            else if fOwner.PartialFileName(
                             fMsg, nil, nil, @resp.Size) = HTTP_SUCCESS then
              resp.Kind := pcfResponsePartial;
          DoSendResponse;
        end;
      pcfPong,
      pcfResponsePartial,
      pcfResponseFull:
        if not late then
        begin
          inc(fResponses);
          if AddResponseAndDone(fMsg) then
          begin
            fCurrentSeq := 0;            // ignore next responses
            fBroadcastEvent.SetEvent;    // notify MessageBroadcast
          end;
        end;
      pcfResponseNone,
      pcfResponseOverloaded:
        if not late then
          inc(fResponses);
    end
  else // not ok = this UDP packet is invalid
    if fOwner.fInstable <> nil then // RejectInstablePeersMin
      fOwner.fInstable.BanIP(remote.IP4);
end;

function THttpPeerCacheThread.Broadcast(const aReq: THttpPeerCacheMessage;
  out aAlone: boolean): THttpPeerCacheMessageDynArray;
var
  sock: TNetSocket;
  res: TNetResult;
  frame: RawByteString;
  start, stop: Int64;
begin
  result := nil;
  if self = nil then
    exit;
  QueryPerformanceMicroSeconds(start);
  frame := fOwner.MessageEncode(aReq);
  fBroadcastSafe.Lock; // serialize OnDownload() or Ping() calls
  try
    // setup this broadcasting sequence
    fBroadcastEvent.ResetEvent;
    fCurrentSeq := aReq.Seq; // ignore any other responses
    fResponses := 0;         // reset counter for this fCurrentSeq (not late)
    // broadcast request over the UDP sub-net of the selected network interface
    sock := fBroadcastAddr.NewSocket(nlUdp);
    if sock = nil then
      exit;
    try
      sock.SetBroadcast(true);
      res := sock.SendTo(pointer(frame), length(frame), fBroadcastAddr);
      if fOwner.fVerboseLog then
        fOwner.fLog.Add.Log(sllTrace, 'Broadcast: % % = %',
          [fBroadcastIpPort, ToText(aReq), ToText(res)^], self);
      if res <> nrOk then
        exit;
    finally
      sock.Close;
    end;
    // wait for the (first) response(s)
    fBroadcastEvent.WaitFor(fOwner.Settings.BroadcastTimeoutMS);
    result := GetResponses(aReq.Seq);
  finally
    fCurrentSeq := 0; // ignore any late responses
    aAlone := (fResponses = 0);
    fBroadcastSafe.UnLock;
  end;
  QueryPerformanceMicroSeconds(stop);
  fOwner.fLog.Add.Log(sllTrace, 'Broadcast: %=%/% in %',
    [ToText(aReq.Kind)^, length(result), fResponses,
     MicroSecToString(stop - start)], self);
end;

function THttpPeerCacheThread.AddResponseAndDone(
  const aMessage: THttpPeerCacheMessage): boolean;
begin
  if fRespCount < fOwner.Settings.BroadcastMaxResponses then
  begin
    fRespSafe.Lock;
    try
      if fRespCount = length(fResp) then
        SetLength(fResp, NextGrow(fRespCount));
      fResp[fRespCount] := aMessage;
      inc(fRespCount);
    finally
      fRespSafe.UnLock;
    end;
  end;
  result := (pcoUseFirstResponse in fOwner.Settings.Options) or
            (fRespCount >= fOwner.Settings.BroadcastMaxResponses);
end;

function THttpPeerCacheThread.GetResponses(
  aSeq: cardinal): THttpPeerCacheMessageDynArray;
var
  i, c, n: PtrInt;
begin
  result := nil;
  // retrieve the pending responses
  fCurrentSeq := 0; // no more reponse from now on
  fRespSafe.Lock;
  try
    if fRespCount = 0 then
      exit;
    pointer(result) := pointer(fResp); // assign with no refcount
    pointer(fResp) := nil;
    c := fRespCount;
    fRespCount := 0;
  finally
    fRespSafe.UnLock;
  end;
  // filter the responses matching aSeq (paranoid)
  n := 0;
  for i := 0 to c - 1 do
    if result[i].Seq = aSeq then
    begin
      if i <> n then
        result[n] := result[i];
      inc(n);
    end;
  if n = 0 then
    result := nil
  else
    DynArrayFakeLength(result, n);
end;

procedure THttpPeerCacheThread.OnIdle(tix64: Int64);
begin
  fOwner.OnIdle(tix64); // do nothing but once every minute
end;

procedure THttpPeerCacheThread.OnShutdown;
begin
  // nothing to be done in our case
end;


{ THttpPeerCache }

constructor THttpPeerCache.Create(aSettings: THttpPeerCacheSettings;
  const aSharedSecret: RawByteString;
  aHttpServerClass: THttpServerSocketGenericClass;
  aHttpServerThreadCount: integer; aLogClass: TSynLogClass;
  aServerTls, aClientTls: PNetTlsContext);
var
  log: ISynLog;
  avail, existing: Int64;
begin
  fLog := aLogClass;
  if fLog = nil then
    fLog := TSynLog;
  log := fLog.Enter('Create threads=%', [aHttpServerThreadCount], self);
  fFilesSafe.Init;
  // intialize the cryptographic state in inherited THttpPeerCrypt.Create
  if (fSettings = nil) or
     (fSettings.Uuid = '') then // allow UUID customization
    GetComputerUuid(fUuid)
  else if not RawUtf8ToGuid(fSettings.Uuid, fUuid) then
    EHttpPeerCache.RaiseUtf8('Invalid %.Create(uuid=%)', [self, fSettings.Uuid]);
  inherited Create(aSharedSecret, aServerTls, aClientTls);
  // setup the processing options
  if aSettings = nil then
  begin
    fSettings := THttpPeerCacheSettings.Create;
    fSettingsOwned := true;
  end
  else
    fSettings := aSettings;
  fVerboseLog := (pcoVerboseLog in fSettings.Options) and
                 (sllTrace in fLog.Family.Level);
  // check the temporary files cache folder and its maximum allowed size
  if fSettings.CacheTempPath = '*' then // not customized
    fSettings.CacheTempPath := TemporaryFileName;
  fTempFilesPath := EnsureDirectoryExists(fSettings.CacheTempPath);
  if fTempFilesPath <> '' then
  begin
    OnIdle(0); // initial clean-up
    fTempFilesMaxSize := Int64(fSettings.CacheTempMaxMB) shl 20;
    avail := GetDiskAvailable(fTempFilesPath);
    existing := DirectorySize(fTempFilesPath, false, PEER_CACHE_PATTERN);
    if Assigned(log) then
      log.Log(sllDebug, 'Create: % folder has % available, with % existing cache',
        [fTempFilesPath, KB(avail), KB(existing)], self);
    if avail <> 0 then
    begin
      avail := (avail + existing) shr 2;
      if fTempFilesMaxSize > avail then
      begin
        fTempFilesMaxSize := avail; // allow up to 25% of the folder capacity
        if Assigned(log) then
          log.Log(sllDebug, 'Create: use CacheTempMax=%', [KB(avail)], self);
      end;
    end;
  end;
  // ensure we have somewhere to cache
  if fSettings.CachePermPath = '*' then // not customized
    fSettings.CachePermPath := MakePath(
      [GetSystemPath(spCommonData), Executable.ProgramName, 'permcache']);
  fPermFilesPath := EnsureDirectoryExists(fSettings.CachePermPath);
  if (fTempFilesPath = '') and
     (fPermFilesPath = '') then
    EHttpPeerCache.RaiseUtf8('%.Create: no cache defined', [self]);
  // retrieve the local network interface (in inherited THttpPeerCrypt)
  AfterSettings; // fSettings should have been defined
  // start the local UDP server on this interface
  fUdpServer := THttpPeerCacheThread.Create(self);
  if Assigned(log) then
    log.Log(sllTrace, 'Create: started %', [fUdpServer], self);
  // start the local HTTP/HTTPS server on this interface
  if not (pcoNoServer in fSettings.Options) then
  begin
    StartHttpServer(aHttpServerClass, aHttpServerThreadCount, fIpPort);
    fHttpServer.ServerName := Executable.ProgramName;
    fHttpServer.OnBeforeBody := OnBeforeBody;
    fHttpServer.OnRequest := OnRequest;
    if Assigned(log) then
      log.Log(sllDebug, 'Create: started %', [fHttpServer], self);
  end;
end;

procedure THttpPeerCache.StartHttpServer(
  aHttpServerClass: THttpServerSocketGenericClass;
  aHttpServerThreadCount: integer; const aIP: RawUtf8);
var
  opt: THttpServerOptions;
begin
  if fClientTls.Enabled <> fServerTls.Enabled then
    EHttpPeerCache.RaiseUtf8(
      '%.StartHttpServer: inconsistent ClientTls=% ServerTls=%',
      [self, fClientTls.Enabled, fServerTls.Enabled]);
  if aHttpServerClass = nil then
    aHttpServerClass := THttpServer; // classic per-thread client is good enough
  opt := [hsoNoXPoweredHeader, hsoThreadSmooting];
  if not (pcoNoBanIP in fSettings.Options) then // RejectInstablePeersMin = UDP
    include(opt, hsoBan40xIP);
  if fVerboseLog then
    include(opt, hsoLogVerbose);
  if fServerTls.Enabled or
     (pcoSelfSignedHttps in fSettings.Options) then
    include(opt, hsoEnableTls);
  fHttpServer := aHttpServerClass.Create(aIP, nil,
    fLog.Family.OnThreadEnded, 'PeerCache', aHttpServerThreadCount, 30000, opt);
  if aHttpServerClass.InheritsFrom(THttpServerSocketGeneric) then
  begin
    // note: both THttpServer and THttpAsyncServer support rfProgressiveStatic
    fPartials := THttpPartials.Create;
    if fVerboseLog then
      fPartials.OnLog := fLog.DoLog;
    THttpServerSocketGeneric(fHttpServer).fOnProgressiveRequestFree := fPartials;
    // actually start and wait for the local HTTP server to be available
    if fServerTls.Enabled then
    begin
      fLog.Add.Log(sllTrace, 'StartHttpServer: HTTPS from ServerTls', self);
      THttpServerSocketGeneric(fHttpServer).WaitStarted(10, @fServerTls);
    end
    else if pcoSelfSignedHttps in fSettings.Options then
    begin
      fLog.Add.Log(sllTrace, 'StartHttpServer: self-signed HTTPS', self);
      THttpServerSocketGeneric(fHttpServer).WaitStartedHttps(10);
    end
    else
      THttpServerSocketGeneric(fHttpServer).WaitStarted(10);
  end;
end;

function THttpPeerCache.CurrentConnections: integer;
begin
  if pcoNoServer in fSettings.Options then
    result := 0
  else
    result := fHttpServer.ConnectionsActive;
end;

destructor THttpPeerCache.Destroy;
begin
  if fSettingsOwned then
    fSettings.Free;
  fSettings := nil; // notify OnDownload/OnIdle/OnFrameReceived calls
  FreeAndNil(fUdpServer);
  FreeAndNil(fHttpServer);
  FreeAndNil(fPartials);
  fFilesSafe.Done;
  inherited Destroy;
end;

function THttpPeerCache.Check(Status: THttpPeerCryptMessageDecode;
  const Ctxt: ShortString; const Msg: THttpPeerCacheMessage): boolean;
var
  msgtxt: shortstring;
begin
  result := (Status = mdOk);
  if fLog <> nil then
    with fLog.Family do
      if sllTrace in Level then
      begin
        msgtxt[0] := #0;
        if fVerboseLog and
           (Status > mdAes) then
          MsgToShort(Msg, msgtxt); // decrypt ok: log the content
        Add.Log(sllTrace, '% decode=% #%<=#% %',
          [Ctxt, ToText(Status)^, CardinalToHexShort(fFrameSeqLow),
           CardinalToHexShort(fFrameSeq), msgtxt], self);
      end;
end;

function THttpPeerCache.ComputeFileName(const aHash: THashDigest): TFileName;
begin
  // filename is binary algo + hash encoded as hexadecimal
  result := FormatString('%.cache',
    [BinToHexLower(@aHash, SizeOf(aHash.Algo) + HASH_SIZE[aHash.Algo])]);
  // note: it does not make sense to obfuscate this file name because we can
  // recompute the hash from its actual content since it's not encrypted at rest
end;

function THttpPeerCache.PermFileName(const aFileName: TFileName;
  aFlags: THttpPeerCacheLocalFileName): TFileName;
begin
  if pcoCacheTempSubFolders in fSettings.Options then
  begin
    // create sub-folders using the first hash nibble (0..9/a..z), in a way
    // similar to git - aFileName[1..2] is the algorithm, so hash starts at [3]
    result := MakePath([fPermFilesPath, aFileName[3]]);
    if lfnEnsureDirectoryExists in aFlags then
      result := EnsureDirectoryExists(result);
    result := result + aFileName;
  end
  else
    result := fPermFilesPath + aFileName;
end;

function THttpPeerCache.LocalFileName(const aMessage: THttpPeerCacheMessage;
  aFlags: THttpPeerCacheLocalFileName; aFileName: PFileName;
  aSize: PInt64): integer;
var
  perm, temp, name, fn: TFileName;
  size: Int64;
begin
  name := ComputeFileName(aMessage.Hash);
  if fPermFilesPath <> '' then
    perm := PermFileName(name, aFlags); // with pcoCacheTempSubFolders support
  if fTempFilesPath <> '' then
    temp := fTempFilesPath + name;
  fFilesSafe.Lock; // disable any concurrent file access
  try
    size := FileSize(perm); // fast syscall on all platforms
    if size <> 0 then
      fn := perm            // found in permanent cache folder
    else
    begin
      size := FileSize(temp);
      if size <> 0 then
      begin
        fn := temp;      // found in temporary cache folder
        if lfnSetDate in aFlags then
          FileSetDateFromUnixUtc(temp, UnixTimeUtc); // renew TTL
      end;
    end;
  finally
    fFilesSafe.UnLock;
  end;
  if fVerboseLog then
    fLog.Add.Log(sllTrace, 'LocalFileName: % size=% msg: size=% start=% end=%',
      [fn, size, aMessage.Size, aMessage.RangeStart, aMessage.RangeEnd], self);
  result := HTTP_NOTFOUND;
  if size = 0 then
    exit; // not existing
  result := HTTP_NOTACCEPTABLE;
  if (aMessage.Size <> 0) and // ExpectedSize may be 0 if waoNoHeadFirst was set
     (size <> aMessage.Size) then
    exit; // invalid file
  result := HTTP_SUCCESS;
  if aFileName <> nil then
    aFileName^ := fn;
  if aSize <> nil then
    aSize^ := size;
end;

function WGetToHash(const Params: THttpClientSocketWGet;
  out Hash: THashDigest): boolean;
begin
  result := false;
  if (Params.Hash = '') or
     (Params.Hasher = nil) or
     not Params.Hasher.InheritsFrom(TStreamRedirectSynHasher) then
    exit; // no valid hash for sure
  Hash.Algo := TStreamRedirectSynHasherClass(Params.Hasher).GetAlgo;
  result := mormot.core.text.HexToBin(
    pointer(Params.Hash), @Hash.Bin, HASH_SIZE[Hash.Algo]);
end;

function THttpPeerCache.CachedFileName(const aParams: THttpClientSocketWGet;
  aFlags: THttpPeerCacheLocalFileName;
  out aLocal: TFileName; out isTemp: boolean): boolean;
var
  hash: THashDigest;
begin
  if not WGetToHash(aParams, hash) then
  begin
    result := false;
    exit;
  end;
  aLocal := ComputeFileName(hash);
  isTemp := (fPermFilesPath = '') or
            not (waoPermanentCache in aParams.AlternateOptions);
  if isTemp then
    aLocal := fTempFilesPath + aLocal
  else
    aLocal := PermFileName(aLocal, aFlags); // with sub-folder
  result := true;
end;

function THttpPeerCache.TooSmallFile(const aParams: THttpClientSocketWGet;
  aSize: Int64; const aCaller: shortstring): boolean;
var
  minsize: Int64;
begin
  result := false; // continue
  if waoNoMinimalSize in aParams.AlternateOptions then
    exit;
  if (waoPermanentCache in aParams.AlternateOptions) and
     (fPermFilesPath <> '') then
    minsize := fSettings.CachePermMinBytes
  else
    minsize := fSettings.CacheTempMinBytes;
  if aSize >= minsize then
    exit; // big enough
  if fVerboseLog then
    fLog.Add.Log(sllTrace, '%: size < minsize=%', [aCaller, KB(minsize)], self);
  result := true; // too small
end;

function SortMessagePerPriority(const VA, VB): integer;
var
  a: THttpPeerCacheMessage absolute VA;
  b: THttpPeerCacheMessage absolute VB;
begin
  result := CompareCardinal(ord(b.Kind), ord(a.Kind));
  if result <> 0 then // pcfResponseFull first
    exit;
  result := CompareCardinal(NETHW_ORDER[a.Hardware], NETHW_ORDER[b.Hardware]);
  if result <> 0 then // ethernet first
    exit;
  result := CompareCardinal(b.Speed, a.Speed);
  if result <> 0 then // highest speed first
    exit;
  result := CompareCardinal(a.Connections, b.Connections);
  if result <> 0 then // less active
    exit;
  result := ComparePointer(@a, @b); // by pointer = received first
end;

function THttpPeerCache.OnDownload(Sender: THttpClientSocket;
  var Params: THttpClientSocketWGet; const Url: RawUtf8;
  ExpectedFullSize: Int64; OutStream: TStreamRedirect): integer;
var
  req: THttpPeerCacheMessage;
  resp : THttpPeerCacheMessageDynArray;
  fn: TFileName;
  u: RawUtf8;
  local: TFileStreamEx;
  i: PtrInt;
  tix: cardinal;
  outStreamInitialPos: Int64;
  alone: boolean;
  log: ISynLog;
  l: TSynLog;

  function ResetOutStreamPosition: boolean;
  begin
    // not moved (e.g. first request, or connection issue) returns true
    result := OutStream.Position = outStreamInitialPos;
    if not result then
      // TStreamRedirect requires full rewind for full content re-hash
      if outStreamInitialPos = 0 then
        result := OutStream.Seek(0, soBeginning) = 0; // will call ReHash
      // TODO: fix range support - TStreamRedirect.Seek() Rehash after Append()
  end;

begin
  result := 0;
  // validate WGet caller context
  if (self = nil) or
     (fSettings = nil) or
     (Sender = nil) or
     (Params.Hash = '') or
     (Url = '') or
     (OutStream = nil) then
    exit;
  if not Params.Hasher.InheritsFrom(TStreamRedirectSynHasher) then
    EHttpPeerCache.RaiseUtf8('%.OnDownload: unexpected %', [Params.Hasher]);
  outStreamInitialPos := OutStream.Position;
  // prepare a request frame
  l := nil;
  log := fLog.Enter('OnDownload % % % %', [KBNoSpace(ExpectedFullSize),
    Params.Hasher.GetHashName, Params.Hash, Url], self);
  if Assigned(log) then // log=nil if fLog=nil or sllEnter is not enabled
    l := log.Instance;
  MessageInit(pcfRequest, 0, req);
  if not WGetToHash(Params, req.Hash) then
  begin
    l.Log(sllWarning, 'OnDownload: invalid hash=%', [Params.Hash], self);
    exit;
  end;
  req.Size := ExpectedFullSize; // may be 0 if waoNoHeadFirst
  req.RangeStart := Sender.RangeStart;
  req.RangeEnd := Sender.RangeEnd;
  // always check if we don't already have this file cached locally
  if not (pcoNoServer in fSettings.Options) and
     (LocalFileName(req, [lfnSetDate], @fn, @req.Size) = HTTP_SUCCESS) then
  begin
    l.Log(sllDebug, 'OnDownload: from local %', [fn], self);
    local := TFileStreamEx.Create(fn, fmOpenReadShared);
    try
      // range support
      if req.RangeStart > 0 then
        req.RangeStart := local.Seek(req.RangeStart, soBeginning);
      if (req.RangeEnd <= 0) or
         (req.RangeEnd >= req.Size) then
        req.RangeEnd := req.Size - 1;
      req.Size := req.RangeEnd - req.RangeStart + 1;
      // fetch the data
      if req.Size > 0 then
      begin
        OutStream.LimitPerSecond := 0; // not relevant within the same process
        OutStream.CopyFrom(local, req.Size);
      end;
    finally
      local.Free;
    end;
    if req.RangeStart > 0 then
      result := HTTP_PARTIALCONTENT
    else
      result := HTTP_SUCCESS;
    Params.SetStep(wgsAlternateFromCache, [fn]);
    exit;
  end;
  // ensure the file is big enough for broadcasting
  if (ExpectedFullSize <> 0) and
     TooSmallFile(Params, ExpectedFullSize, 'OnDownload') then
    exit; // you are too small, buddy
  // try first the current/last HTTP client (if any)
  FormatUtf8('?%=%', [Sender.Server, Url], u); // url used only for log/debugging
  if (fClient <> nil) and
     (fClientIP4 <> 0) and
     ((pcoTryLastPeer in fSettings.Options) or
      (waoTryLastPeer in Params.AlternateOptions)) and
     fClientSafe.TryLock then
    try
      SetLength(resp, 1); // create a "fake" response to reuse this connection
      resp[0] := req;
      FillZero(resp[0].Uuid);
      // OnRequest() returns HTTP_NOCONTENT (204) - and not 404 - if not found
      result := LocalPeerRequest(req, resp[0], u, OutStream, {aRetry=}true);
      if result in [HTTP_SUCCESS, HTTP_PARTIALCONTENT] then
      begin
        Params.SetStep(wgsAlternateLastPeer, [fClient.Server]);
        exit; // successful direct downloading from last peer
      end;
      result := 0; // may be HTTP_NOCONTENT (204) if not found on this peer
    finally
      fClientSafe.UnLock;
    end;
  // broadcast the request over UDP
  tix := 0;
  if (pcoBroadcastNotAlone in fSettings.Options) or
     (waoBroadcastNotAlone in Params.AlternateOptions) then
  begin
    tix := (GetTickCount64 shr MilliSecsPerSecShl) + 1; // 1024 ms resolution
    if fBroadcastTix = tix then  // disable broadcasting within up to 1s delay
      exit;
  end;
  Params.SetStep(wgsAlternateBroadcast, [fUdpServer.fBroadcastIpPort]);
  resp := fUdpServer.Broadcast(req, alone);
  if resp = nil then
  begin
    if (tix <> 0) and // pcoBroadcastNotAlone
       alone then
      fBroadcastTix := tix; // no broadcast within the next second
    exit; // no match
  end;
  fBroadcastTix := 0; // resp<>nil -> broadcasting seems fine
  // select the best responses
  if length(resp) <> 1 then
    DynArray(TypeInfo(THttpPeerCacheMessageDynArray), resp).
      Sort(SortMessagePerPriority);
  // HTTP/HTTPS request over the best peer corresponding to this response
  Params.SetStep(wgsAlternateGet, [IP4ToShort(@resp[0].IP4)]);
  if not ResetOutStreamPosition then
    exit; // partial download would fail the hash anyway
  fClientSafe.Lock;
  try
    result := LocalPeerRequest(req, resp[0], u, OutStream, {aRetry=}false);
  finally
    fClientSafe.UnLock;
  end;
  if (result in [HTTP_SUCCESS, HTTP_PARTIALCONTENT]) or
     not ResetOutStreamPosition or // rewind OutStream for main server fallback
     not ((pcoTryAllPeers in fSettings.Options) or
          (waoTryAllPeers in Params.AlternateOptions)) then
    exit;
  // try up to the best TryAllPeersCount peers of our broadcast response
  for i := 1 to MinPtrInt(length(resp), fSettings.TryAllPeersCount) do
    if not fInstable.IsBanned(resp[i].IP4) then // banned in-between (unlikely)
      if fClientSafe.TryLock then
      try
        Params.SetStep(wgsAlternateGetNext, [IP4ToShort(@resp[i].IP4)]);
        result := LocalPeerRequest(req, resp[i], u, OutStream, {aRetry=}false);
        if (result in [HTTP_SUCCESS, HTTP_PARTIALCONTENT]) or
           not ResetOutStreamPosition then
          exit;
      finally
        fClientSafe.UnLock;
      end;
end;

function THttpPeerCache.Ping: THttpPeerCacheMessageDynArray;
var
  req: THttpPeerCacheMessage;
  alone: boolean;
begin
  MessageInit(pcfPing, 0, req);
  result := fUdpServer.Broadcast(req, alone);
end;

type
  TOnBeforeBodyErr = set of (
    eBearer, eGet, eUrl, eIp1, eBanned, eDecode, eIp2, eUuid,
    eDirectIp, eDirectDecode, eDirectOpaque, aDirectDisabled);

function THttpPeerCache.OnBeforeBody(var aUrl, aMethod, aInHeaders,
  aInContentType, aRemoteIP, aBearerToken: RawUtf8; aContentLength: Int64;
  aFlags: THttpServerRequestFlags): cardinal;
var
  msg: THttpPeerCacheMessage;
  ip4: cardinal;
  err: TOnBeforeBodyErr;
begin
  // should return HTTP_SUCCESS=200 to continue the process, or an HTTP
  // error code to reject the request immediately as a "TeaPot", close the
  // socket and ban this IP for a few seconds at accept() level
  err := [];
  if length(aBearerToken) < (SizeOf(msg) div 3) * 4 then // base64uri length
    include(err, eBearer);
  if not IsGet(aMethod) then
    include(err, eGet);
  if aUrl = '' then // URI is just ignored but something should be specified
    include(err, eUrl)
  else if PCardinal(aUrl)^ = DIRECTURI_32 then
  begin
    // pcfBearerDirect for pcoHttpDirect mode: /https/microsoft.com/...
    if (aRemoteIp <> '') and
       not IsLocalHost(pointer(aRemoteIP)) then
      include(err, eDirectIp);
    if not Check(BearerDecode(aBearerToken, pcfBearerDirect, msg),
             'OnBeforeBody Direct', msg) then
      include(err, eDirectDecode)
    else if Int64(msg.Opaque) <> crc63c(pointer(aUrl), length(aUrl)) then
      include(err, eDirectOpaque); // see THttpPeerCrypt.HttpDirectUri()
    if not (pcoHttpDirect in fSettings.Options) then
      include(err, aDirectDisabled);
  end
  else
  begin
    // pcfBearer for regular request in broadcasting mode
    if not IPToCardinal(aRemoteIP, ip4) then
      include(err, eIp1)
    else if fInstable.IsBanned(ip4) then // banned for RejectInstablePeersMin
      include(err, eBanned);
    if err = [] then
      if Check(BearerDecode(aBearerToken, pcfBearer, msg), 'OnBeforeBody', msg) then
      begin
        if msg.IP4 <> fIP4 then
          include(err, eIp2);
        if not ((IsZero(THash128(msg.Uuid)) or // IsZero for "fake" response bearer
               IsEqualGuid(msg.Uuid, fUuid))) then
          include(err, eUuid);
      end
      else
        include(err, eDecode);
  end;
  result := HTTP_SUCCESS;
  if err <> [] then
    result := HTTP_FORBIDDEN;
  if fVerboseLog or
     (err <> []) then
    fLog.Add.Log(sllTrace, 'OnBeforeBody=% % % % [%]', [result, aRemoteIP,
      aMethod, aUrl, GetSetNameShort(TypeInfo(TOnBeforeBodyErr), @err)], self);
end;

procedure THttpPeerCache.OnIdle(tix64: Int64);
var
  tix: cardinal;
  size: Int64;
begin
  // avoid GPF at shutdown
  if fSettings = nil then
    exit;
  // check state every minute (65,536 seconds)
  if tix64 = 0 then
    tix64 := GetTickCount64;
  tix := (tix64 shr 16) + 1; 
  // renew banned peer IPs TTL to implement RejectInstablePeersMin
  if (fInstable <> nil) and
     (fInstableTix <> tix) then
  begin
    fInstableTix := tix;
    if fInstable.Count <> 0 then
      if fInstable.DoRotate <> 0 then
        fLog.Add.Log(sllTrace, 'OnIdle: %', [fInstable], self);
  end;
  // handle temporary cache folder deprecation
  if (fSettings.CacheTempMaxMin <= 0) or
     (fTempFilesPath = '') then
    exit;
  if (fTempFilesDeleteDeprecatedTix <> tix) and
     fFilesSafe.TryLock then
  try
    fTempFilesDeleteDeprecatedTix := tix;
    DirectoryDeleteOlderFiles(fTempFilesPath,
      fSettings.CacheTempMaxMin / MinsPerDay, PEER_CACHE_PATTERN, false, @size);
    if size = 0 then
      exit; // nothing changed on disk
    fLog.Add.Log(sllTrace, 'OnIdle: deleted %', [KBNoSpace(size)], self);
    fTempCurrentSize := 0; // we need to call FindFiles()
  finally
    fFilesSafe.UnLock; // re-allow background file access
  end;
end;

procedure THttpPeerCache.OnDowloaded(var Params: THttpClientSocketWGet;
  const Partial: TFileName; PartialID: integer);
var
  local: TFileName;
  localsize, sourcesize, tot, start, stop, deleted: Int64;
  ok, istemp: boolean;
  i: PtrInt;
  dir: TFindFilesDynArray;
begin
  if pcoNoServer in fSettings.Options then
    exit;
  // the supplied downloaded source file should be big enough
  sourcesize := FileSize(Partial);
  if (sourcesize = 0) or // paranoid
     TooSmallFile(Params, sourcesize, 'OnDownloaded') then
    exit;
  // compute the local cache file name from the known file hash
  if not CachedFileName(Params, [lfnEnsureDirectoryExists], local, istemp) then
  begin
    fLog.Add.Log(sllWarning,
      'OnDowloaded: no hash specified for %', [Partial], self);
    exit;
  end;
  // check if this file was not already in the cache folder
  // - outside fFilesSafe.Lock because happens just after OnDownload from cache
  localsize := FileSize(local);
  if localsize <> 0 then
  begin
    fLog.Add.Log(LOG_TRACEWARNING[localsize <> sourcesize],
      'OnDowloaded: % already in cache', [Partial], self);
    // size mismatch may happen on race condition (hash collision is unlikely)
    if PartialID <> 0 then
      fPartials.ChangeFile(PartialID, local); // switch to the local file
    if localsize = sourcesize then
      Params.SetStep(wgsAlternateAlreadyInCache, [local])
    else
      Params.SetStep(wgsAlternateWrongSizeInCache,
        [local, ' ', localsize, '<>', sourcesize]); // paranaoid
    exit;
  end;
  QueryPerformanceMicroSeconds(start);
  fFilesSafe.Lock; // disable any concurrent file access
  try
    // ensure adding this file won't trigger the maximum cache size limit
    if (fTempFilesMaxSize > 0) and
       istemp then
    begin
      if sourcesize >= fTempFilesMaxSize then
        tot := sourcesize // this file is oversized for sure
      else
      begin
        // compute the current folder cache size
        tot := fTempCurrentSize;
        if tot = 0 then // first time, or after OnIdle
        begin
          dir := FindFiles(fTempFilesPath, PEER_CACHE_PATTERN);
          for i := 0 to high(dir) do
            inc(tot, dir[i].Size);
          fTempCurrentSize := tot;
        end;
        inc(tot, sourcesize); // simulate adding this file
        if tot >= fTempFilesMaxSize then
        begin
          // delete oldest files in cache up to CacheTempMaxMB
          if dir = nil then
            dir := FindFiles(fTempFilesPath, PEER_CACHE_PATTERN);
          FindFilesSortByTimestamp(dir);
          deleted := 0;
          for i := 0 to high(dir) do
            if DeleteFile(dir[i].Name) then // if not currently downloading
            begin
              dec(tot, dir[i].Size);
              inc(deleted, dir[i].Size);
              if tot < fTempFilesMaxSize then
                break; // we have deleted enough old files
            end;
          fLog.Add.Log(sllTrace, 'OnDowloaded: deleted %', [KB(deleted)], self);
          dec(fTempCurrentSize, deleted);
        end;
      end;
      if tot >= fTempFilesMaxSize then
      begin
        fLog.Add.Log(sllDebug, 'OnDowloaded: % is too big (%) for tot=%',
          [Partial, KBNoSpace(sourcesize), KBNoSpace(tot)], self);
        if PartialID <> 0 then
          OnDownloadingFailed(PartialID); // abort partial downloading
        exit;
      end;
    end;
    // actually copy the source file into the local cache folder
    ok := CopyFile(Partial, local, {failsifexists=}false);
    Params.SetStep(wgsAlternateCopiedInCache, [local]);
    if ok and istemp then
      // force timestamp = now within the temporary folder
      FileSetDateFromUnixUtc(local, UnixTimeUtc)
  finally
    fFilesSafe.UnLock;
  end;
  if PartialID <> 0 then
    if ok then
      fPartials.ChangeFile(PartialID, local) // switch to final local file
    else
      OnDownloadingFailed(PartialID);     // abort
  QueryPerformanceMicroSeconds(stop);
  fLog.Add.Log(LOG_TRACEWARNING[not ok], 'OnDowloaded: copy % into % in %',
      [Partial, local, MicroSecToString(stop - start)], self);
end;

procedure THttpPeerCache.OnDownloadFailed(const Params: THttpClientSocketWGet);
var
  local: TFileName;
  istemp: boolean;
begin
  // compute the local cache file name from the known file hash
  if not CachedFileName(Params, [lfnEnsureDirectoryExists], local, istemp) then
    fLog.Add.Log(sllWarning, 'OnDowloadFailed: missing hash', self)
  // actually delete the local (may be corrupted) file
  else if DeleteFile(local) then
    fLog.Add.Log(sllTrace, 'OnDowloadFailed: deleted %', [local], self)
  else
    fLog.Add.Log(sllLastError, 'OnDowloadFailed: error deleting %', [local], self);
end;

function THttpPeerCache.OnDownloading(const Params: THttpClientSocketWGet;
  const Partial: TFileName; ExpectedFullSize: Int64): THttpPartialID;
var
  h: THashDigest;
begin
  if (fPartials = nil) or // not supported by this fHttpServer class
     (waoNoProgressiveDownloading in Params.AlternateOptions) or
     not WGetToHash(Params, h) or
     TooSmallFile(Params, ExpectedFullSize, 'OnDownloading') then
    result := 0
  else
    result := fPartials.Add(Partial, ExpectedFullSize, h);
end;

function THttpPeerCache.PartialFileName(
  const aMessage: THttpPeerCacheMessage; aHttp: PHttpRequestContext;
  aFileName: PFileName; aSize: PInt64): integer;
var
  fn: TFileName;
  size: Int64;
begin
  result := HTTP_NOTFOUND;
  if fPartials = nil then // not supported by this fHttpServer class
    exit;
  fn := fPartials.Find(aMessage.Hash, aHttp, size);
  if fVerboseLog then
    fLog.Add.Log(sllTrace, 'PartialFileName: % size=% msg: size=% start=% end=%',
      [fn, size, aMessage.Size, aMessage.RangeStart, aMessage.RangeEnd], self);
  if size = 0 then
    exit; // not existing
  result := HTTP_NOTACCEPTABLE;
  if (aMessage.Size <> 0) and // ExpectedSize may be 0 if waoNoHeadFirst was set
     (size <> aMessage.Size) then
    exit; // invalid file
  result := HTTP_SUCCESS;
  if aFileName <> nil then
    aFileName^ := fn;
  if aSize <> nil then
    aSize^ := size;
end;

procedure THttpPeerCache.OnDownloadingFailed(ID: THttpPartialID);
begin
  // unregister and abort any partial downloading process
  if fPartials.Abort(ID) <> 0 then
    SleepHiRes(500); // wait for THttpServer.Process abort
end;

function THttpPeerCache.OnRequest(Ctxt: THttpServerRequestAbstract): cardinal;
var
  msg: THttpPeerCacheMessage;
  fn: TFileName;
  progsize: Int64; // expected progressive file size, to be supplied as header
begin
  // retrieve context - already checked by OnBeforeBody
  result := HTTP_BADREQUEST;
  if Check(BearerDecode(Ctxt.AuthBearer, pcfRequest, msg), 'OnRequest', msg) then
  try
    // get local filename from decoded bearer hash
    progsize := 0;
    case msg.Kind of
      pcfBearer:
        begin
          // after UDP: download from LocalFileName() or PartialFileName()
          result := LocalFileName(msg, [lfnSetDate], @fn, nil);
          if (result <> HTTP_SUCCESS) and
             (fPartials <> nil) then // if supported by the fHttpServer class
            result := PartialFileName(
                        msg, (Ctxt as THttpServerRequest).fHttp, @fn, @progsize);
        end;
      pcfBearerDirect:
        begin
          // perform a HEAD to the original server to retrieve progsize

          // start the proper request to the remote URI

        end;
    end;
    if result <> HTTP_SUCCESS then
    begin
      if IsZero(THash128(msg.Uuid)) then // from "fake" response bearer
        result := HTTP_NOCONTENT;        // OnDownload should make a broadcast
      exit;
    end;
    // just return the (partial) file as requested
    Ctxt.OutContent := StringToUtf8(fn);
    Ctxt.OutContentType := STATICFILE_CONTENT_TYPE;
    if progsize <> 0 then // header for rfProgressiveStatic mode
      Ctxt.OutCustomHeaders := FormatUtf8(STATICFILE_PROGSIZE + ' %', [progsize]);
  finally
    fLog.Add.Log(sllDebug, 'OnRequest=% from % % as % %',
      [result, Ctxt.RemoteIP, Ctxt.Url, fn, progsize], self);
  end;
end;


function ToText(pcf: THttpPeerCacheMessageKind): PShortString;
begin
  result := GetEnumName(TypeInfo(THttpPeerCacheMessageKind), ord(pcf));
end;

function ToText(md: THttpPeerCryptMessageDecode): PShortString;
begin
  result := GetEnumName(TypeInfo(THttpPeerCryptMessageDecode), ord(md));
end;

function ToText(const msg: THttpPeerCacheMessage): shortstring;
begin
  MsgToShort(msg, result);
end;

procedure MsgToShort(const msg: THttpPeerCacheMessage; var result: shortstring);
var
  l: PtrInt;
  algo: PUtf8Char;
  hex: string[SizeOf(msg.Hash.Bin.b) * 2];
begin
  l := 0;
  algo := nil;
  if not IsZero(msg.Hash.Bin.b) then
  begin
    algo := pointer(HASH_EXT[msg.Hash.Algo]);
    l := HASH_SIZE[msg.Hash.Algo];
    BinToHexLower(@msg.Hash.Bin, @hex[1], l);
  end;
  hex[0] := AnsiChar(l * 2);
  with msg do
    FormatShort('% #% % % % to % % % msk=% bst=% %Mb/s %% siz=%',
      [ToText(Kind)^, CardinalToHexShort(Seq), GuidToShort(Uuid), OS_NAME[Os.os],
       IP4ToShort(@IP4), IP4ToShort(@DestIP4), ToText(Hardware)^,
       UnixTimeToFileShort(QWord(Timestamp) + UNIXTIME_MINIMAL),
       IP4ToShort(@MaskIP4), IP4ToShort(@BroadcastIP4), Speed,
       hex, algo, Size], result);
end;

{$ifdef USEWININET}

{ **************** THttpApiServer HTTP/1.1 Server Over Windows http.sys Module }

{ THttpApiServer }

function THttpApiServer.AddUrl(const aRoot, aPort: RawUtf8; Https: boolean;
  const aDomainName: RawUtf8; aRegisterUri: boolean; aContext: Int64): integer;
var
  uri: SynUnicode;
  n: integer;
begin
  result := -1;
  if (Self = nil) or
     (fReqQueue = 0) or
     (Http.Module = 0) then
    exit;
  uri := RegURL(aRoot, aPort, Https, aDomainName);
  if uri = '' then
    exit; // invalid parameters
  if aRegisterUri then
    AddUrlAuthorize(aRoot, aPort, Https, aDomainName);
  if Http.Version.MajorVersion > 1 then
    result := Http.AddUrlToUrlGroup(fUrlGroupID, pointer(uri), aContext)
  else
    result := Http.AddUrl(fReqQueue, pointer(uri));
  if result = NO_ERROR then
  begin
    n := length(fRegisteredUnicodeUrl);
    SetLength(fRegisteredUnicodeUrl, n + 1);
    fRegisteredUnicodeUrl[n] := uri;
  end;
end;

function THttpApiServer.RemoveUrl(const aRoot, aPort: RawUtf8; Https: boolean;
  const aDomainName: RawUtf8): integer;
var
  uri: SynUnicode;
  i, j, n: PtrInt;
begin
  result := -1;
  if (Self = nil) or
     (fReqQueue = 0) or
     (Http.Module = 0) then
    exit;
  uri := RegURL(aRoot, aPort, Https, aDomainName);
  if uri = '' then
    exit; // invalid parameters
  n := High(fRegisteredUnicodeUrl);
  for i := 0 to n do
    if fRegisteredUnicodeUrl[i] = uri then
    begin
      if Http.Version.MajorVersion > 1 then
        result := Http.RemoveUrlFromUrlGroup(fUrlGroupID, pointer(uri), 0)
      else
        result := Http.RemoveUrl(fReqQueue, pointer(uri));
      if result <> 0 then
        exit; // shall be handled by caller
      for j := i to n - 1 do
        fRegisteredUnicodeUrl[j] := fRegisteredUnicodeUrl[j + 1];
      SetLength(fRegisteredUnicodeUrl, n);
      exit;
    end;
end;

class function THttpApiServer.AddUrlAuthorize(const aRoot, aPort: RawUtf8;
  Https: boolean; const aDomainName: RawUtf8; OnlyDelete: boolean): string;
const
  /// will allow AddUrl() registration to everyone
  // - 'GA' (GENERIC_ALL) to grant all access
  // - 'S-1-1-0'	defines a group that includes all users
  HTTPADDURLSECDESC: PWideChar = 'D:(A;;GA;;;S-1-1-0)';
var
  prefix: SynUnicode;
  err: HRESULT;
  cfg: HTTP_SERVICE_CONFIG_URLACL_SET;
begin
  try
    HttpApiInitialize;
    prefix := RegURL(aRoot, aPort, Https, aDomainName);
    if prefix = '' then
      result := 'Invalid parameters'
    else
    begin
      EHttpApiServer.RaiseOnError(hInitialize,
        Http.Initialize(Http.Version, HTTP_INITIALIZE_CONFIG));
      try
        FillcharFast(cfg, SizeOf(cfg), 0);
        cfg.KeyDesc.pUrlPrefix := pointer(prefix);
        // first delete any existing information
        err := Http.DeleteServiceConfiguration(
          0, hscUrlAclInfo, @cfg, SizeOf(cfg));
        // then add authorization rule
        if not OnlyDelete then
        begin
          cfg.KeyDesc.pUrlPrefix := pointer(prefix);
          cfg.ParamDesc.pStringSecurityDescriptor := HTTPADDURLSECDESC;
          err := Http.SetServiceConfiguration(
            0, hscUrlAclInfo, @cfg, SizeOf(cfg));
        end;
        if (err <> NO_ERROR) and
           (err <> ERROR_ALREADY_EXISTS) then
          raise EHttpApiServer.Create(hSetServiceConfiguration, err);
        result := ''; // success
      finally
        Http.Terminate(HTTP_INITIALIZE_CONFIG);
      end;
    end;
  except
    on E: Exception do
      result := E.Message;
  end;
end;

type
  THttpApiServerClass = class of THttpApiServer;

procedure THttpApiServer.Clone(ChildThreadCount: integer);
var
  i: PtrInt;
begin
  if (fReqQueue = 0) or
     (not Assigned(OnRequest)) or
     (ChildThreadCount <= 0) or
     (fClones <> nil) then
    exit; // nothing to clone (need a queue and a process event)
  if ChildThreadCount > 256 then
    ChildThreadCount := 256; // not worth adding
  SetLength(fClones, ChildThreadCount);
  for i := 0 to ChildThreadCount - 1 do
    fClones[i] := THttpApiServerClass(PClass(self)^).CreateClone(self);
end;

function THttpApiServer.GetApiVersion: RawUtf8;
begin
  FormatUtf8('http.sys %.%',
    [Http.Version.MajorVersion, Http.Version.MinorVersion], result);
end;

constructor THttpApiServer.Create(QueueName: SynUnicode;
  const OnStart, OnStop: TOnNotifyThread; const ProcessName: RawUtf8;
  ProcessOptions: THttpServerOptions);
var
  binding: HTTP_BINDING_INFO;
begin
  SetLength(fLogDataStorage, SizeOf(HTTP_LOG_FIELDS_DATA)); // should be done 1st
  inherited Create(OnStart, OnStop, ProcessName, ProcessOptions + [hsoCreateSuspended]);
  fOptions := ProcessOptions;
  HttpApiInitialize; // will raise an exception in case of failure
  EHttpApiServer.RaiseOnError(hInitialize,
    Http.Initialize(Http.Version, HTTP_INITIALIZE_SERVER));
  if Http.Version.MajorVersion > 1 then
  begin
    EHttpApiServer.RaiseOnError(hCreateServerSession,
      Http.CreateServerSession(Http.Version, fServerSessionID));
    EHttpApiServer.RaiseOnError(hCreateUrlGroup,
      Http.CreateUrlGroup(fServerSessionID, fUrlGroupID));
    if QueueName = '' then
      Utf8ToSynUnicode(Int64ToUtf8(fServerSessionID), QueueName);
    EHttpApiServer.RaiseOnError(hCreateRequestQueue,
      Http.CreateRequestQueue(Http.Version, pointer(QueueName), nil, 0, fReqQueue));
    binding.Flags := 1;
    binding.RequestQueueHandle := fReqQueue;
    EHttpApiServer.RaiseOnError(hSetUrlGroupProperty,
      Http.SetUrlGroupProperty(fUrlGroupID, HttpServerBindingProperty,
        @binding, SizeOf(binding)));
  end
  else
    EHttpApiServer.RaiseOnError(hCreateHttpHandle,
      Http.CreateHttpHandle(fReqQueue));
  fReceiveBufferSize := 1 shl 20; // i.e. 1 MB
  if Suspended then
    Suspended := false;
end;

constructor THttpApiServer.CreateClone(From: THttpApiServer);
begin
  SetLength(fLogDataStorage, SizeOf(HTTP_LOG_FIELDS_DATA));
  fOwner := From;
  fReqQueue := From.fReqQueue;
  fOnRequest := From.fOnRequest;
  fOnBeforeBody := From.fOnBeforeBody;
  fOnBeforeRequest := From.fOnBeforeRequest;
  fOnAfterRequest := From.fOnAfterRequest;
  fOnAfterResponse := From.fOnAfterResponse;
  fMaximumAllowedContentLength := From.fMaximumAllowedContentLength;
  fCallbackSendDelay := From.fCallbackSendDelay;
  fCompress := From.fCompress;
  fCompressAcceptEncoding := From.fCompressAcceptEncoding;
  fReceiveBufferSize := From.fReceiveBufferSize;
  if From.fLogData <> nil then
    fLogData := pointer(fLogDataStorage);
  fOptions := From.fOptions; // needed by SetServerName() below
  fLogger := From.fLogger;   // share same THttpLogger instance
  SetServerName(From.fServerName); // setters are sometimes needed
  SetRemoteIPHeader(From.fRemoteIPHeader);
  SetRemoteConnIDHeader(From.fRemoteConnIDHeader);
  fLoggingServiceName := From.fLoggingServiceName;
  inherited Create(From.fOnThreadStart, From.fOnThreadTerminate,
    From.fProcessName, From.fOptions - [hsoCreateSuspended]);
end;

procedure THttpApiServer.DestroyMainThread;
var
  i: PtrInt;
begin
  if fReqQueue <> 0 then
  begin
    for i := 0 to length(fClones) - 1 do
      fClones[i].Terminate; // for CloseHandle() below to finish Execute
    if Http.Version.MajorVersion > 1 then
    begin
      if fUrlGroupID <> 0 then
      begin
        Http.RemoveUrlFromUrlGroup(fUrlGroupID, nil, HTTP_URL_FLAG_REMOVE_ALL);
        Http.CloseUrlGroup(fUrlGroupID);
        fUrlGroupID := 0;
      end;
      CloseHandle(fReqQueue);
      if fServerSessionID <> 0 then
      begin
        Http.CloseServerSession(fServerSessionID);
        fServerSessionID := 0;
      end;
    end
    else
    begin
      for i := 0 to high(fRegisteredUnicodeUrl) do
        Http.RemoveUrl(fReqQueue, pointer(fRegisteredUnicodeUrl[i]));
      CloseHandle(fReqQueue); // will break all THttpApiServer.Execute
    end;
    fReqQueue := 0;
    {$ifdef FPC}
    for i := 0 to length(fClones) - 1 do
      WaitForSingleObject(fClones[i].Handle, 30000); // sometimes needed on FPC
    {$endif FPC}
    for i := 0 to length(fClones) - 1 do
      fClones[i].Free;
    fClones := nil;
    Http.Terminate(HTTP_INITIALIZE_SERVER);
  end;
end;

destructor THttpApiServer.Destroy;
begin
  Terminate; // for Execute to be notified about end of process
  try
    if (fOwner = nil) and
       (Http.Module <> 0) then // fOwner<>nil for cloned threads
      DestroyMainThread;
    {$ifdef FPC}
    WaitForSingleObject(Handle, 30000); // sometimes needed on FPC
    {$endif FPC}
    if fOwner <> nil then
      fLogger := nil; // to be released only by the main thread
  finally
    inherited Destroy;
  end;
end;

function THttpApiServer.GetSendResponseFlags(Ctxt: THttpServerRequest): integer;
begin
  result := 0;
end;

type
  TVerbText = array[hvOPTIONS..pred(hvMaximum)] of RawUtf8;

const
  VERB_TEXT: TVerbText = (
    'OPTIONS',
    'GET',
    'HEAD',
    'POST',
    'PUT',
    'DELETE',
    'TRACE',
    'CONNECT',
    'TRACK',
    'MOVE',
    'COPY',
    'PROPFIND',
    'PROPPATCH',
    'MKCOL',
    'LOCK',
    'UNLOCK',
    'SEARCH');

var
  global_verbs: TVerbText; // to avoid memory allocation on Delphi

procedure THttpApiServer.Execute;
var
  req: PHTTP_REQUEST;
  reqid: HTTP_REQUEST_ID;
  reqbuf, respbuf: RawByteString;
  i: PtrInt;
  bytesread, bytessent, flags: cardinal;
  err: HRESULT;
  compressset: THttpSocketCompressSet;
  incontlen: Qword;
  incontlenchunk, incontlenread: cardinal;
  incontenc, inaccept, host, range, referer: RawUtf8;
  outcontenc, outstat: RawUtf8;
  outstatcode, afterstatcode: cardinal;
  respsent: boolean;
  urirouter: TUriRouter;
  ctxt: THttpServerRequest;
  filehandle: THandle;
  resp: PHTTP_RESPONSE;
  bufread, V: PUtf8Char;
  heads: HTTP_UNKNOWN_HEADERs;
  rangestart, rangelen: ULONGLONG;
  outcontlen: ULARGE_INTEGER;
  datachunkmem: HTTP_DATA_CHUNK_INMEMORY;
  datachunkfile: HTTP_DATA_CHUNK_FILEHANDLE;
  logdata: PHTTP_LOG_FIELDS_DATA;
  started, elapsed: Int64;
  contrange: ShortString;

  procedure SendError(StatusCode: cardinal; const ErrorMsg: RawUtf8;
    E: Exception = nil);
  var
    msg: RawUtf8;
  begin
    try
      resp^.SetStatus(StatusCode, outstat);
      logdata^.ProtocolStatus := StatusCode;
      FormatUtf8('<!DOCTYPE html><html><body style="font-family:verdana;">' +
        '<h1>Server Error %: %</h1><p>', [StatusCode, outstat], msg);
      if E <> nil then
        msg := FormatUtf8('%% Exception raised:<br>', [msg, E]);
      msg := msg + HtmlEscape(ErrorMsg) + ('</p><p><small>' + XPOWEREDVALUE);
      resp^.SetContent(datachunkmem, msg, 'text/html; charset=utf-8');
      Http.SendHttpResponse(fReqQueue, req^.RequestId, 0, resp^, nil,
        bytessent, nil, 0, nil, fLogData);
    except
      on Exception do
        ; // ignore any HttpApi level errors here (client may crashed)
    end;
  end;

  function SendResponse: boolean;
  var
    R: PUtf8Char;
    flags: cardinal;
  begin
    result := not Terminated; // true=success
    if not result then
      exit;
    respsent := true;
    resp^.SetStatus(outstatcode, outstat);
    if Terminated then
      exit;
    // update log information
    if Http.Version.MajorVersion >= 2 then
      with req^, logdata^ do
      begin
        MethodNum := Verb;
        UriStemLength := CookedUrl.AbsPathLength;
        UriStem := CookedUrl.pAbsPath;
        with headers.KnownHeaders[reqUserAgent] do
        begin
          UserAgentLength := RawValueLength;
          UserAgent := pRawValue;
        end;
        with headers.KnownHeaders[reqHost] do
        begin
          HostLength := RawValueLength;
          Host := pRawValue;
        end;
        with headers.KnownHeaders[reqReferrer] do
        begin
          ReferrerLength := RawValueLength;
          Referrer := pRawValue;
        end;
        ProtocolStatus := resp^.StatusCode;
        ClientIp := pointer(ctxt.fRemoteIP);
        ClientIpLength := length(ctxt.fRemoteip);
        Method := pointer(ctxt.fMethod);
        MethodLength := length(ctxt.fMethod);
        UserName := pointer(ctxt.fAuthenticatedUser);
        UserNameLength := Length(ctxt.fAuthenticatedUser);
      end;
    // send response
    resp^.Version := req^.Version;
    resp^.SetHeaders(pointer(ctxt.OutCustomHeaders),
      heads, hsoNoXPoweredHeader in fOptions);
    if fCompressAcceptEncoding <> '' then
      resp^.AddCustomHeader(pointer(fCompressAcceptEncoding), heads, false);
    with resp^.headers.KnownHeaders[respServer] do
    begin
      pRawValue := pointer(fServerName);
      RawValueLength := length(fServerName);
    end;
    if ctxt.OutContentType = STATICFILE_CONTENT_TYPE then
    begin
      // response is file -> OutContent is UTF-8 file name to be served
      filehandle := FileOpen(Utf8ToString(ctxt.OutContent), fmOpenReadShared);
      if not ValidHandle(filehandle)  then
      begin
        SendError(HTTP_NOTFOUND, WinErrorText(GetLastError, nil));
        result := false; // notify fatal error
      end;
      try // http.sys will serve then close the file from kernel
        datachunkfile.DataChunkType := hctFromFileHandle;
        datachunkfile.filehandle := filehandle;
        flags := 0;
        datachunkfile.ByteRange.StartingOffset.QuadPart := 0;
        Int64(datachunkfile.ByteRange.Length.QuadPart) := -1; // to eof
        with req^.headers.KnownHeaders[reqRange] do
        begin
          if (RawValueLength > 6) and
             IdemPChar(pointer(pRawValue), 'BYTES=') and
             (pRawValue[6] in ['0'..'9']) then
          begin
            FastSetString(range, pRawValue + 6, RawValueLength - 6); // need #0 end
            R := pointer(range);
            rangestart := GetNextRange(R);
            if R^ = '-' then
            begin
              outcontlen.QuadPart := FileSize(filehandle);
              datachunkfile.ByteRange.Length.QuadPart :=
                outcontlen.QuadPart - rangestart;
              inc(R);
              flags := HTTP_SEND_RESPONSE_FLAG_PROCESS_RANGES;
              datachunkfile.ByteRange.StartingOffset.QuadPart := rangestart;
              if R^ in ['0'..'9'] then
              begin
                rangelen := GetNextRange(R) - rangestart + 1;
                if Int64(rangelen) < 0 then
                  rangelen := 0;
                if rangelen < datachunkfile.ByteRange.Length.QuadPart then
                  // "bytes=0-499" -> start=0, len=500
                  datachunkfile.ByteRange.Length.QuadPart := rangelen;
              end; // "bytes=1000-" -> start=1000, to eof
              FormatShort('Content-range: bytes %-%/%'#0, [rangestart,
                rangestart + datachunkfile.ByteRange.Length.QuadPart - 1,
                outcontlen.QuadPart], contrange);
              resp^.AddCustomHeader(@contrange[1], heads, false);
              resp^.SetStatus(HTTP_PARTIALCONTENT, outstat);
            end;
          end;
        end;
        with resp^.headers.KnownHeaders[respAcceptRanges] do
        begin
          pRawValue := 'bytes';
          RawValueLength := 5;
        end;
        resp^.EntityChunkCount := 1;
        resp^.pEntityChunks := @datachunkfile;
        Http.SendHttpResponse(fReqQueue, req^.RequestId, flags, resp^, nil,
          bytessent, nil, 0, nil, fLogData);
      finally
        FileClose(filehandle);
      end;
    end
    else
    begin
      // response is in OutContent -> send it from memory
      if ctxt.OutContentType = NORESPONSE_CONTENT_TYPE then
        ctxt.OutContentType := ''; // true HTTP always expects a response
      if fCompress <> nil then
      begin
        with resp^.headers.KnownHeaders[reqContentEncoding] do
          if RawValueLength = 0 then
          begin
            // no previous encoding -> try if any compression
            CompressContent(compressset, fCompress, ctxt.OutContentType,
              ctxt.fOutContent, outcontenc);
            pRawValue := pointer(outcontenc);
            RawValueLength := length(outcontenc);
          end;
      end;
      resp^.SetContent(datachunkmem, ctxt.OutContent, ctxt.OutContentType);
      flags := GetSendResponseFlags(ctxt);
      EHttpApiServer.RaiseOnError(hSendHttpResponse,
        Http.SendHttpResponse(fReqQueue, req^.RequestId, flags, resp^, nil,
          bytessent, nil, 0, nil, fLogData));
    end;
  end;

begin
  if Terminated then
    exit;
  ctxt := nil;
  try
    // THttpServerGeneric thread preparation: launch any OnHttpThreadStart event
    NotifyThreadStart(self);
    // reserve working buffers
    SetLength(heads, 64);
    SetLength(respbuf, SizeOf(HTTP_RESPONSE));
    resp := pointer(respbuf);
    SetLength(reqbuf, 16384 + SizeOf(HTTP_REQUEST)); // req^ + 16 KB of headers
    req := pointer(reqbuf);
    logdata := pointer(fLogDataStorage);
    if global_verbs[hvOPTIONS] = '' then
      global_verbs := VERB_TEXT;
    ctxt := THttpServerRequest.Create(self, 0, self, 0, [], nil);
    // main loop reusing a single ctxt instance for this thread
    reqid := 0;
    ctxt.fServer := self;
    repeat
      // release input/output body buffers ASAP
      ctxt.fInContent := '';
      ctxt.fOutContent := '';
      // retrieve next pending request, and read its headers
      FillcharFast(req^, SizeOf(HTTP_REQUEST), 0);
      err := Http.ReceiveHttpRequest(fReqQueue, reqid, 0,
        req^, length(reqbuf), bytesread); // blocking until received something
      if Terminated then
        break;
      case err of
        NO_ERROR:
          try
            // parse method and main headers as ctxt.Prepare() does
            bytessent := 0;
            ctxt.fHttpApiRequest := req;
            ctxt.Recycle(req^.ConnectionID, self, {asynchandle=}0,
              HTTP_TLS_FLAGS[req^.pSslInfo <> nil] +
              // no HTTP_UPG_FLAGS[]: plain THttpApiServer don't support upgrade
              HTTP_10_FLAGS[(req^.Version.MajorVersion = 1) and
                            (req^.Version.MinorVersion = 0)],
              // ctxt.fConnectionOpaque is not supported by http.sys
              nil);
            FastSetString(ctxt.fUrl, req^.pRawUrl, req^.RawUrlLength);
            if req^.Verb in [low(global_verbs)..high(global_verbs)] then
              ctxt.fMethod := global_verbs[req^.Verb]
            else
              FastSetString(ctxt.fMethod, req^.pUnknownVerb, req^.UnknownVerbLength);
            with req^.headers.KnownHeaders[reqContentType] do
              FastSetString(ctxt.fInContentType, pRawValue, RawValueLength);
            with req^.headers.KnownHeaders[reqUserAgent] do
              FastSetString(ctxt.fUserAgent, pRawValue, RawValueLength);
            with req^.headers.KnownHeaders[reqHost] do
              FastSetString(ctxt.fHost, pRawValue, RawValueLength);
            host := ctxt.Host; // may be reset during Request()
            with req^.Headers.KnownHeaders[reqAuthorization] do
              if (RawValueLength > 7) and
                 IdemPChar(pointer(pRawValue), 'BEARER ') then
                FastSetString(ctxt.fAuthBearer, pRawValue + 7, RawValueLength - 7);
            with req^.headers.KnownHeaders[reqAcceptEncoding] do
              FastSetString(inaccept, pRawValue, RawValueLength);
            with req^.headers.KnownHeaders[reqReferrer] do
              FastSetString(referer, pRawValue, RawValueLength);
            compressset := ComputeContentEncoding(fCompress, pointer(inaccept));
            ctxt.fInHeaders := RetrieveHeadersAndGetRemoteIPConnectionID(
              req^, fRemoteIPHeaderUpper, fRemoteConnIDHeaderUpper,
              {out} ctxt.fRemoteIP, PQWord(@ctxt.fConnectionID)^);
            // retrieve any SetAuthenticationSchemes() information
            if byte(fAuthenticationSchemes) <> 0 then // set only with HTTP API 2.0
              // https://docs.microsoft.com/en-us/windows/win32/http/authentication-in-http-version-2-0
              for i := 0 to req^.RequestInfoCount - 1 do
                if req^.pRequestInfo^[i].InfoType = HttpRequestInfoTypeAuth then
                  with PHTTP_REQUEST_AUTH_INFO(req^.pRequestInfo^[i].pInfo)^ do
                    case AuthStatus of
                      HttpAuthStatusSuccess:
                        if AuthType > HttpRequestAuthTypeNone then
                        begin
                          byte(ctxt.fAuthenticationStatus) := ord(AuthType) + 1;
                          if AccessToken <> 0 then
                          begin
                            ctxt.fAuthenticatedUser := LookupToken(AccessToken);
                            // AccessToken lifecycle is application responsibility
                            CloseHandle(AccessToken);
                            ctxt.fAuthBearer := ctxt.fAuthenticatedUser;
                            include(ctxt.fConnectionFlags, hsrAuthorized);
                          end;
                        end;
                      HttpAuthStatusFailure:
                        ctxt.fAuthenticationStatus := hraFailed;
                    end;
            // abort request if > MaximumAllowedContentLength or OnBeforeBody
            with req^.headers.KnownHeaders[reqContentLength] do
            begin
              V := pointer(pRawValue);
              SetQWord(V, V + RawValueLength, incontlen);
            end;
            if (incontlen > 0) and
               (fMaximumAllowedContentLength > 0) and
               (incontlen > QWord(fMaximumAllowedContentLength)) then
            begin
              SendError(HTTP_PAYLOADTOOLARGE, 'Rejected');
              continue;
            end;
            if Assigned(OnBeforeBody) then
            begin
              err := OnBeforeBody(ctxt.fUrl, ctxt.fMethod, ctxt.fInHeaders,
                ctxt.fInContentType, ctxt.fRemoteIP, ctxt.fAuthBearer, incontlen,
                ctxt.ConnectionFlags);
              if err <> HTTP_SUCCESS then
              begin
                SendError(err, 'Rejected');
                continue;
              end;
            end;
            // retrieve body
            if HTTP_REQUEST_FLAG_MORE_ENTITY_BODY_EXISTS and req^.flags <> 0 then
            begin
              with req^.headers.KnownHeaders[reqContentEncoding] do
                FastSetString(incontenc, pRawValue, RawValueLength);
              if incontlen <> 0 then
              begin
                // receive body chunks
                SetLength(ctxt.fInContent, incontlen);
                bufread := pointer(ctxt.InContent);
                incontlenread := 0;
                repeat
                  bytesread := 0;
                  if Http.Version.MajorVersion > 1 then
                    // speed optimization for Vista+
                    flags := HTTP_RECEIVE_REQUEST_ENTITY_BODY_FLAG_FILL_BUFFER
                  else
                    flags := 0;
                  incontlenchunk := incontlen - incontlenread;
                  if (fReceiveBufferSize >= 1024) and
                     (incontlenchunk > fReceiveBufferSize) then
                    incontlenchunk := fReceiveBufferSize;
                  err := Http.ReceiveRequestEntityBody(fReqQueue,
                    req^.RequestId, flags, bufread, incontlenchunk, bytesread);
                  if Terminated then
                    exit;
                  inc(incontlenread, bytesread);
                  if err = ERROR_HANDLE_EOF then
                  begin
                    if incontlenread < incontlen then
                      SetLength(ctxt.fInContent, incontlenread);
                    err := NO_ERROR;
                    break; // should loop until returns ERROR_HANDLE_EOF
                  end;
                  if err <> NO_ERROR then
                    break;
                  inc(bufread, bytesread);
                until incontlenread = incontlen;
                if err <> NO_ERROR then
                begin
                  SendError(HTTP_NOTACCEPTABLE, WinErrorText(err, HTTPAPI_DLL));
                  continue;
                end;
                // optionally uncompress input body
                if incontenc <> '' then
                  for i := 0 to high(fCompress) do
                    if fCompress[i].Name = incontenc then
                    begin
                      fCompress[i].Func(ctxt.fInContent, false); // uncompress
                      break;
                    end;
              end;
            end;
            QueryPerformanceMicroSeconds(started);
            try
              // compute response
              FillcharFast(resp^, SizeOf(resp^), 0);
              respsent := false;
              outstatcode := 0;
              if fOwner = nil then
                urirouter := fRoute
              else
                urirouter := fOwner.fRoute; // field not propagated in clones
              if urirouter <> nil then
                // URI rewrite or event callback execution
                outstatcode := urirouter.Process(Ctxt);
              if outstatcode = 0 then // no router callback was executed
              begin
                // regular server-side OnRequest execution
                outstatcode := DoBeforeRequest(ctxt);
                if outstatcode > 0 then
                  if not SendResponse or
                     (outstatcode <> HTTP_ACCEPTED) then
                    continue;
                outstatcode := Request(ctxt); // call OnRequest for main process
                afterstatcode := DoAfterRequest(ctxt);
                if afterstatcode > 0 then
                  outstatcode := afterstatcode;
              end;
              // send response
              if not respsent then
                if not SendResponse then
                  continue;
              QueryPerformanceMicroSeconds(elapsed);
              dec(elapsed, started);
              ctxt.Host := host; // may have been reset during Request()
              DoAfterResponse(
                ctxt, referer, outstatcode, elapsed, incontlen, bytessent);
            except
              on E: Exception do
                // handle any exception raised during process: show must go on!
                if not respsent then
                  if not E.InheritsFrom(EHttpApiServer) or // ensure still connected
                    (EHttpApiServer(E).LastApiError <> HTTPAPI_ERROR_NONEXISTENTCONNECTION) then
                    SendError(HTTP_SERVERERROR, StringToUtf8(E.Message), E);
            end;
          finally
            reqid := 0; // reset Request ID to handle the next pending request
          end;
        ERROR_MORE_DATA:
          begin
            // input buffer was too small to hold the request headers
            // -> increase buffer size and call the API again
            reqid := req^.RequestId;
            SetLength(reqbuf, bytesread);
            req := pointer(reqbuf);
          end;
        ERROR_CONNECTION_INVALID:
          if reqid = 0 then
            break
          else
            // TCP connection was corrupted by the peer -> ignore + next request
            reqid := 0;
      else
        break; // unhandled err value
      end;
    until Terminated;
  finally
    ctxt.Free;
  end;
end;

function THttpApiServer.GetHttpQueueLength: cardinal;
var
  len: ULONG;
begin
  if (Http.Version.MajorVersion < 2) or
     (self = nil) then
    result := 0
  else
  begin
    if fOwner <> nil then
      self := fOwner;
    if fReqQueue = 0 then
      result := 0
    else
      EHttpApiServer.RaiseOnError(hQueryRequestQueueProperty,
        Http.QueryRequestQueueProperty(fReqQueue, HttpServerQueueLengthProperty,
          @result, SizeOf(result), 0, @len, nil));
  end;
end;

procedure THttpApiServer.SetHttpQueueLength(aValue: cardinal);
begin
  if Http.Version.MajorVersion < 2 then
    raise EHttpApiServer.Create(hSetRequestQueueProperty, ERROR_OLD_WIN_VERSION);
  if (self <> nil) and
     (fReqQueue <> 0) then
    EHttpApiServer.RaiseOnError(hSetRequestQueueProperty,
      Http.SetRequestQueueProperty(fReqQueue, HttpServerQueueLengthProperty,
        @aValue, SizeOf(aValue), 0, nil));
end;

function THttpApiServer.GetConnectionsActive: cardinal;
begin
  result := 0; // unsupported
end;

function THttpApiServer.GetRegisteredUrl: SynUnicode;
var
  i: PtrInt;
begin
  if fRegisteredUnicodeUrl = nil then
    result := ''
  else
    result := fRegisteredUnicodeUrl[0];
  for i := 1 to high(fRegisteredUnicodeUrl) do
    result := result + ',' + fRegisteredUnicodeUrl[i];
end;

function THttpApiServer.GetCloned: boolean;
begin
  result := (fOwner <> nil);
end;

procedure THttpApiServer.SetMaxBandwidth(aValue: cardinal);
var
  qos: HTTP_QOS_SETTING_INFO;
  limit: HTTP_BANDWIDTH_LIMIT_INFO;
begin
  if Http.Version.MajorVersion < 2 then
    raise EHttpApiServer.Create(hSetUrlGroupProperty, ERROR_OLD_WIN_VERSION);
  if (self <> nil) and
     (fUrlGroupID <> 0) then
  begin
    if aValue = 0 then
      limit.MaxBandwidth := HTTP_LIMIT_INFINITE
    else if aValue < HTTP_MIN_ALLOWED_BANDWIDTH_THROTTLING_RATE then
      limit.MaxBandwidth := HTTP_MIN_ALLOWED_BANDWIDTH_THROTTLING_RATE
    else
      limit.MaxBandwidth := aValue;
    limit.Flags := 1;
    qos.QosType := HttpQosSettingTypeBandwidth;
    qos.QosSetting := @limit;
    EHttpApiServer.RaiseOnError(hSetServerSessionProperty,
      Http.SetServerSessionProperty(fServerSessionID, HttpServerQosProperty,
        @qos, SizeOf(qos)));
    EHttpApiServer.RaiseOnError(hSetUrlGroupProperty,
      Http.SetUrlGroupProperty(fUrlGroupID, HttpServerQosProperty,
        @qos, SizeOf(qos)));
  end;
end;

function THttpApiServer.GetMaxBandwidth: cardinal;
var
  info: record
    qos: HTTP_QOS_SETTING_INFO;
    limit: HTTP_BANDWIDTH_LIMIT_INFO;
  end;
begin
  if (Http.Version.MajorVersion < 2) or
     (self = nil) then
  begin
    result := 0;
    exit;
  end;
  if fOwner <> nil then
    self := fOwner;
  if fUrlGroupID = 0 then
  begin
    result := 0;
    exit;
  end;
  info.qos.QosType := HttpQosSettingTypeBandwidth;
  info.qos.QosSetting := @info.limit;
  EHttpApiServer.RaiseOnError(hQueryUrlGroupProperty,
    Http.QueryUrlGroupProperty(fUrlGroupID, HttpServerQosProperty,
      @info, SizeOf(info)));
  result := info.limit.MaxBandwidth;
end;

function THttpApiServer.GetMaxConnections: cardinal;
var
  info: record
    qos: HTTP_QOS_SETTING_INFO;
    limit: HTTP_CONNECTION_LIMIT_INFO;
  end;
  len: ULONG;
begin
  if (Http.Version.MajorVersion < 2) or
     (self = nil) then
  begin
    result := 0;
    exit;
  end;
  if fOwner <> nil then
    self := fOwner;
  if fUrlGroupID = 0 then
  begin
    result := 0;
    exit;
  end;
  info.qos.QosType := HttpQosSettingTypeConnectionLimit;
  info.qos.QosSetting := @info.limit;
  EHttpApiServer.RaiseOnError(hQueryUrlGroupProperty,
    Http.QueryUrlGroupProperty(fUrlGroupID, HttpServerQosProperty,
      @info, SizeOf(info), @len));
  result := info.limit.MaxConnections;
end;

procedure THttpApiServer.SetMaxConnections(aValue: cardinal);
var
  qos: HTTP_QOS_SETTING_INFO;
  limit: HTTP_CONNECTION_LIMIT_INFO;
begin
  if Http.Version.MajorVersion < 2 then
    raise EHttpApiServer.Create(hSetUrlGroupProperty, ERROR_OLD_WIN_VERSION);
  if (self <> nil) and
     (fUrlGroupID <> 0) then
  begin
    if aValue = 0 then
      limit.MaxConnections := HTTP_LIMIT_INFINITE
    else
      limit.MaxConnections := aValue;
    limit.Flags := 1;
    qos.QosType := HttpQosSettingTypeConnectionLimit;
    qos.QosSetting := @limit;
    EHttpApiServer.RaiseOnError(hSetUrlGroupProperty,
      Http.SetUrlGroupProperty(fUrlGroupID, HttpServerQosProperty,
        @qos, SizeOf(qos)));
  end;
end;

function THttpApiServer.HasApi2: boolean;
begin
  result := Http.Version.MajorVersion >= 2;
end;

function THttpApiServer.GetLogging: boolean;
begin
  result := (fLogData <> nil);
end;

procedure THttpApiServer.LogStart(const aLogFolder: TFileName;
  aType: THttpApiLoggingType; const aSoftwareName: TFileName;
  aRolloverType: THttpApiLoggingRollOver; aRolloverSize: cardinal;
  aLogFields: THttpApiLogFields; aFlags: THttpApiLoggingFlags);
var
  log: HTTP_LOGGING_INFO;
  folder, software: SynUnicode;
begin
  if (self = nil) or
     (fOwner <> nil) then
    exit;
  if Http.Version.MajorVersion < 2 then
    raise EHttpApiServer.Create(hSetUrlGroupProperty, ERROR_OLD_WIN_VERSION);
  fLogData := nil; // disable any previous logging
  FillcharFast(log, SizeOf(log), 0);
  log.Flags := 1;
  log.LoggingFlags := byte(aFlags);
  if aLogFolder = '' then
    raise EHttpApiServer.CreateFmt('LogStart(aLogFolder="")', []);
  if length(aLogFolder) > 212 then
    // http://msdn.microsoft.com/en-us/library/windows/desktop/aa364532
    raise EHttpApiServer.CreateFmt('aLogFolder is too long for LogStart(%s)', [aLogFolder]);
  folder := SynUnicode(aLogFolder);
  software := SynUnicode(aSoftwareName);
  log.SoftwareNameLength := length(software) * 2;
  log.SoftwareName := pointer(software);
  log.DirectoryNameLength := length(folder) * 2;
  log.DirectoryName := pointer(folder);
  log.Format := HTTP_LOGGING_TYPE(aType);
  if aType = hltNCSA then
    aLogFields := [hlfDate..hlfSubStatus];
  log.Fields := integer(aLogFields);
  log.RolloverType := HTTP_LOGGING_ROLLOVER_TYPE(aRolloverType);
  if aRolloverType = hlrSize then
    log.RolloverSize := aRolloverSize;
  EHttpApiServer.RaiseOnError(hSetUrlGroupProperty,
    Http.SetUrlGroupProperty(fUrlGroupID, HttpServerLoggingProperty,
      @log, SizeOf(log)));
  // on success, update the actual log memory structure
  fLogData := pointer(fLogDataStorage);
end;

procedure THttpApiServer.RegisterCompress(aFunction: THttpSocketCompress;
  aCompressMinSize, aPriority: integer);
var
  i: PtrInt;
begin
  inherited;
  for i := 0 to length(fClones) - 1 do
    fClones[i].RegisterCompress(aFunction, aCompressMinSize, aPriority);
end;

procedure THttpApiServer.SetOnTerminate(const Event: TOnNotifyThread);
var
  i: PtrInt;
begin
  inherited SetOnTerminate(Event);
  if fOwner = nil then
    for i := 0 to length(fClones) - 1 do
      fClones[i].OnHttpThreadTerminate := Event;
end;

procedure THttpApiServer.LogStop;
var
  i: PtrInt;
begin
  if (self = nil) or
     (fClones = nil) or
     (fLogData = nil) then
    exit;
  fLogData := nil;
  for i := 0 to length(fClones) - 1 do
    fClones[i].fLogData := nil;
end;

procedure THttpApiServer.SetReceiveBufferSize(Value: cardinal);
var
  i: PtrInt;
begin
  fReceiveBufferSize := Value;
  for i := 0 to length(fClones) - 1 do
    fClones[i].fReceiveBufferSize := Value;
end;

procedure THttpApiServer.SetServerName(const aName: RawUtf8);
var
  i: PtrInt;
begin
  inherited SetServerName(aName);
  with PHTTP_LOG_FIELDS_DATA(fLogDataStorage)^ do
  begin
    ServerName := pointer(aName);
    ServerNameLength := Length(aName);
  end;
  for i := 0 to length(fClones) - 1 do
    fClones[i].SetServerName(aName);
end;

procedure THttpApiServer.SetOnRequest(const aRequest: TOnHttpServerRequest);
var
  i: PtrInt;
begin
  inherited SetOnRequest(aRequest);
  for i := 0 to length(fClones) - 1 do
    fClones[i].SetOnRequest(aRequest);
end;

procedure THttpApiServer.SetOnBeforeBody(const aEvent: TOnHttpServerBeforeBody);
var
  i: PtrInt;
begin
  inherited SetOnBeforeBody(aEvent);
  for i := 0 to length(fClones) - 1 do
    fClones[i].SetOnBeforeBody(aEvent);
end;

procedure THttpApiServer.SetOnBeforeRequest(const aEvent: TOnHttpServerRequest);
var
  i: PtrInt;
begin
  inherited SetOnBeforeRequest(aEvent);
  for i := 0 to length(fClones) - 1 do
    fClones[i].SetOnBeforeRequest(aEvent);
end;

procedure THttpApiServer.SetOnAfterRequest(const aEvent: TOnHttpServerRequest);
var
  i: PtrInt;
begin
  inherited SetOnAfterRequest(aEvent);
  for i := 0 to length(fClones) - 1 do
    fClones[i].SetOnAfterRequest(aEvent);
end;

procedure THttpApiServer.SetOnAfterResponse(const aEvent: TOnHttpServerAfterResponse);
var
  i: PtrInt;
begin
  inherited SetOnAfterResponse(aEvent);
  for i := 0 to length(fClones) - 1 do
    fClones[i].SetOnAfterResponse(aEvent);
end;

procedure THttpApiServer.SetMaximumAllowedContentLength(aMax: Int64);
var
  i: PtrInt;
begin
  inherited SetMaximumAllowedContentLength(aMax);
  for i := 0 to length(fClones) - 1 do
    fClones[i].SetMaximumAllowedContentLength(aMax);
end;

procedure THttpApiServer.SetRemoteIPHeader(const aHeader: RawUtf8);
var
  i: PtrInt;
begin
  inherited SetRemoteIPHeader(aHeader);
  for i := 0 to length(fClones) - 1 do
    fClones[i].SetRemoteIPHeader(aHeader);
end;

procedure THttpApiServer.SetRemoteConnIDHeader(const aHeader: RawUtf8);
var
  i: PtrInt;
begin
  inherited SetRemoteConnIDHeader(aHeader);
  for i := 0 to length(fClones) - 1 do
    fClones[i].SetRemoteConnIDHeader(aHeader);
end;

procedure THttpApiServer.SetLoggingServiceName(const aName: RawUtf8);
begin
  if self = nil then
    exit;
  fLoggingServiceName := aName;
  with PHTTP_LOG_FIELDS_DATA(fLogDataStorage)^ do
  begin
    ServiceName := pointer(fLoggingServiceName);
    ServiceNameLength := Length(fLoggingServiceName);
  end;
end;

procedure THttpApiServer.SetAuthenticationSchemes(
  schemes: THttpApiRequestAuthentications; const DomainName, Realm: SynUnicode);
var
  auth: HTTP_SERVER_AUTHENTICATION_INFO;
begin
  if (self = nil) or
     (fOwner <> nil) then
    exit;
  if Http.Version.MajorVersion < 2 then
    raise EHttpApiServer.Create(hSetUrlGroupProperty, ERROR_OLD_WIN_VERSION);
  fAuthenticationSchemes := schemes;
  FillcharFast(auth, SizeOf(auth), 0);
  auth.Flags := 1;
  auth.AuthSchemes := byte(schemes);
  auth.ReceiveMutualAuth := true;
  if haBasic in schemes then
  begin
    auth.BasicParams.RealmLength := Length(Realm);
    auth.BasicParams.Realm := pointer(Realm);
  end;
  if haDigest in schemes then
  begin
    auth.DigestParams.DomainNameLength := Length(DomainName);
    auth.DigestParams.DomainName := pointer(DomainName);
    auth.DigestParams.RealmLength := Length(Realm);
    auth.DigestParams.Realm := pointer(Realm);
  end;
  EHttpApiServer.RaiseOnError(hSetUrlGroupProperty,
    Http.SetUrlGroupProperty(
      fUrlGroupID, HttpServerAuthenticationProperty, @auth, SizeOf(auth)));
end;

procedure THttpApiServer.SetTimeOutLimits(aEntityBody, aDrainEntityBody,
  aRequestQueue, aIdleConnection, aHeaderWait, aMinSendRate: cardinal);
var
  timeout: HTTP_TIMEOUT_LIMIT_INFO;
begin
  if (self = nil) or
     (fOwner <> nil) then
    exit;
  if Http.Version.MajorVersion < 2 then
    raise EHttpApiServer.Create(hSetUrlGroupProperty, ERROR_OLD_WIN_VERSION);
  FillcharFast(timeout, SizeOf(timeout), 0);
  timeout.Flags := 1;
  timeout.EntityBody := aEntityBody;
  timeout.DrainEntityBody := aDrainEntityBody;
  timeout.RequestQueue := aRequestQueue;
  timeout.IdleConnection := aIdleConnection;
  timeout.HeaderWait := aHeaderWait;
  timeout.MinSendRate := aMinSendRate;
  EHttpApiServer.RaiseOnError(hSetUrlGroupProperty,
    Http.SetUrlGroupProperty(
      fUrlGroupID, HttpServerTimeoutsProperty, @timeout, SizeOf(timeout)));
end;

procedure THttpApiServer.DoAfterResponse(Ctxt: THttpServerRequest;
  const Referer: RawUtf8; StatusCode: cardinal; Elapsed, Received, Sent: QWord);
var
  ctx: TOnHttpServerAfterResponseContext;
begin
  if Assigned(fOnAfterResponse) then
  try
    ctx.Connection := Ctxt.ConnectionID;
    ctx.User := pointer(Ctxt.AuthenticatedUser);
    ctx.Method := pointer(Ctxt.Method);
    ctx.Host := pointer(Ctxt.Host);
    ctx.Url := pointer(Ctxt.Url);
    ctx.Referer := pointer(Referer);
    ctx.UserAgent := pointer(Ctxt.UserAgent);
    ctx.RemoteIP := pointer(Ctxt.RemoteIP);
    ctx.Flags := Ctxt.ConnectionFlags;
    ctx.State := hrsResponseDone;
    ctx.StatusCode := StatusCode;
    ctx.ElapsedMicroSec := Elapsed;
    ctx.Received := Received;
    ctx.Sent := Sent;
    ctx.Tix64 := 0;
    fOnAfterResponse(ctx); // e.g. THttpLogger or THttpAnalyzer
  except
    on E: Exception do // paranoid
      fOnAfterResponse := nil; // won't try again
  end;
end;



{ ****************** THttpApiWebSocketServer Over Windows http.sys Module }

{ THttpApiWebSocketServerProtocol }

const
  WebSocketConnectionCapacity = 1000;

function THttpApiWebSocketServerProtocol.AddConnection(
  aConn: PHttpApiWebSocketConnection): integer;
var
  i: PtrInt;
begin
  if fFirstEmptyConnectionIndex >= fConnectionsCapacity - 1 then
  begin
    inc(fConnectionsCapacity, WebSocketConnectionCapacity);
    ReallocMem(fConnections, fConnectionsCapacity * SizeOf(PHttpApiWebSocketConnection));
    FillcharFast(fConnections^[fConnectionsCapacity - WebSocketConnectionCapacity],
      WebSocketConnectionCapacity * SizeOf(PHttpApiWebSocketConnection), 0);
  end;
  if fFirstEmptyConnectionIndex >= fConnectionsCount then
    fConnectionsCount := fFirstEmptyConnectionIndex + 1;
  fConnections[fFirstEmptyConnectionIndex] := aConn;
  result := fFirstEmptyConnectionIndex;
  for i := fFirstEmptyConnectionIndex + 1 to fConnectionsCount do
  begin
    if fConnections[i] = nil then
    begin
      fFirstEmptyConnectionIndex := i;
      Break;
    end;
  end;
end;

function THttpApiWebSocketServerProtocol.Broadcast(
  aBufferType: WEB_SOCKET_BUFFER_TYPE; aBuffer: pointer;
  aBufferSize: ULONG): boolean;
var
  i: PtrInt;
begin
  EnterCriticalSection(fSafe);
  try
    for i := 0 to fConnectionsCount - 1 do
      if Assigned(fConnections[i]) then
        fConnections[i].Send(aBufferType, aBuffer, aBufferSize);
  finally
    LeaveCriticalSection(fSafe);
  end;
  result := true;
end;

function THttpApiWebSocketServerProtocol.Close(index: integer;
  aStatus: WEB_SOCKET_CLOSE_STATUS; aBuffer: pointer; aBufferSize: ULONG): boolean;
var
  conn: PHttpApiWebSocketConnection;
begin
  result := false;
  if cardinal(index) < cardinal(fConnectionsCount) then
  begin
    conn := fConnections^[index];
    if (conn <> nil) and
       (conn.fState = wsOpen) then
    begin
      conn.Close(aStatus, aBuffer, aBufferSize);
      result := true;
    end;
  end;
end;

constructor THttpApiWebSocketServerProtocol.Create(const aName: RawUtf8;
  aManualFragmentManagement: boolean; aServer: THttpApiWebSocketServer;
  const aOnAccept: TOnHttpApiWebSocketServerAcceptEvent;
  const aOnMessage: TOnHttpApiWebSocketServerMessageEvent;
  const aOnConnect: TOnHttpApiWebSocketServerConnectEvent;
  const aOnDisconnect: TOnHttpApiWebSocketServerDisconnectEvent;
  const aOnFragment: TOnHttpApiWebSocketServerMessageEvent);
begin
  if aManualFragmentManagement and
     (not Assigned(aOnFragment)) then
    raise EWebSocketApi.CreateFmt(
      'Error register WebSocket protocol. Protocol %s does not use buffer, ' +
      'but OnFragment handler is not assigned', [aName]);
  InitializeCriticalSection(fSafe);
  fPendingForClose := TSynList.Create;
  fName := aName;
  fManualFragmentManagement := aManualFragmentManagement;
  fServer := aServer;
  fOnAccept := aOnAccept;
  fOnMessage := aOnMessage;
  fOnConnect := aOnConnect;
  fOnDisconnect := aOnDisconnect;
  fOnFragment := aOnFragment;
  fConnectionsCapacity := WebSocketConnectionCapacity;
  fConnectionsCount := 0;
  fFirstEmptyConnectionIndex := 0;
  fConnections := AllocMem(fConnectionsCapacity * SizeOf(PHttpApiWebSocketConnection));
end;

destructor THttpApiWebSocketServerProtocol.Destroy;
var
  i: PtrInt;
  conn: PHttpApiWebSocketConnection;
begin
  EnterCriticalSection(fSafe);
  try
    for i := 0 to fPendingForClose.Count - 1 do
    begin
      conn := fPendingForClose[i];
      if Assigned(conn) then
      begin
        conn.DoOnDisconnect();
        conn.Disconnect();
        Dispose(conn);
      end;
    end;
    fPendingForClose.Free;
  finally
    LeaveCriticalSection(fSafe);
  end;
  DeleteCriticalSection(fSafe);
  FreeMem(fConnections);
  fConnections := nil;
  inherited;
end;

procedure THttpApiWebSocketServerProtocol.doShutdown;
var
  i: PtrInt;
  conn: PHttpApiWebSocketConnection;
const
  sReason = 'Server shutdown';
begin
  EnterCriticalSection(fSafe);
  try
    for i := 0 to fConnectionsCount - 1 do
    begin
      conn := fConnections[i];
      if Assigned(conn) then
      begin
        RemoveConnection(i);
        conn.fState := wsClosedByShutdown;
        conn.fBuffer := sReason;
        conn.fCloseStatus := WEB_SOCKET_ENDPOINT_UNAVAILABLE_CLOSE_STATUS;
        conn.Close(WEB_SOCKET_ENDPOINT_UNAVAILABLE_CLOSE_STATUS,
          pointer(conn.fBuffer), Length(conn.fBuffer));
// IocpPostQueuedStatus(fServer.fThreadPoolServer.FRequestQueue, 0, 0, @conn.fOverlapped);
      end;
    end;
  finally
    LeaveCriticalSection(fSafe);
  end;
end;

procedure THttpApiWebSocketServerProtocol.RemoveConnection(index: integer);
begin
  fPendingForClose.Add(fConnections[index]);
  fConnections[index] := nil;
  if fFirstEmptyConnectionIndex > index then
    fFirstEmptyConnectionIndex := index;
end;

function THttpApiWebSocketServerProtocol.Send(index: integer;
  aBufferType: WEB_SOCKET_BUFFER_TYPE; aBuffer: pointer; aBufferSize: ULONG): boolean;
var
  conn: PHttpApiWebSocketConnection;
begin
  result := false;
  if (index >= 0) and
     (index < fConnectionsCount) then
  begin
    conn := fConnections^[index];
    if (conn <> nil) and
       (conn.fState = wsOpen) then
    begin
      conn.Send(aBufferType, aBuffer, aBufferSize);
      result := true;
    end;
  end;
end;


 { THttpApiWebSocketConnection }

function THttpApiWebSocketConnection.TryAcceptConnection(
  aProtocol: THttpApiWebSocketServerProtocol;
  Ctxt: THttpServerRequestAbstract; aNeedHeader: boolean): boolean;
var
  req: PHTTP_REQUEST;
  reqhead: WEB_SOCKET_HTTP_HEADER_ARR;
  srvhead: PWEB_SOCKET_HTTP_HEADER;
  srvheadcount: ULONG;
begin
  fState := wsConnecting;
  fBuffer := '';
  fWSHandle := nil;
  fLastActionContext := nil;
  FillcharFast(fOverlapped, SizeOf(fOverlapped), 0);
  fProtocol := aProtocol;
  req := PHTTP_REQUEST((Ctxt as THttpServerRequest).HttpApiRequest);
  fIndex := fProtocol.fFirstEmptyConnectionIndex;
  fOpaqueHTTPRequestId := req^.RequestId;
  if (fProtocol = nil) or
     (Assigned(fProtocol.OnAccept) and
      not fProtocol.OnAccept(Ctxt as THttpServerRequest, Self)) then
  begin
    result := false;
    exit;
  end;
  EWebSocketApi.RaiseOnError(hCreateServerHandle,
    WebSocketApi.CreateServerHandle(nil, 0, fWSHandle));
  reqhead := HttpSys2ToWebSocketHeaders(req^.headers);
  if aNeedHeader then
    result := WebSocketApi.BeginServerHandshake(fWSHandle,
      pointer(fProtocol.name), nil, 0, @reqhead[0], Length(reqhead), srvhead,
      srvheadcount) = S_OK
  else
    result := WebSocketApi.BeginServerHandshake(fWSHandle, nil, nil, 0,
      pointer(reqhead), Length(reqhead),
      srvhead, srvheadcount) = S_OK;
  if result then
  try
    Ctxt.OutCustomHeaders := WebSocketHeadersToText(srvhead, srvheadcount);
  finally
    result := WebSocketApi.EndServerHandshake(fWSHandle) = S_OK;
  end;
  if not result then
    Disconnect
  else
    fLastReceiveTickCount := 0;
end;

procedure THttpApiWebSocketConnection.DoOnMessage(
  aBufferType: WEB_SOCKET_BUFFER_TYPE; aBuffer: pointer; aBufferSize: ULONG);

  procedure PushFragmentIntoBuffer;
  var
    l: integer;
  begin
    l := Length(fBuffer);
    SetLength(fBuffer, l + integer(aBufferSize));
    MoveFast(aBuffer^, fBuffer[l + 1], aBufferSize);
  end;

begin
  if fProtocol = nil then
    exit;
  if (aBufferType = WEB_SOCKET_UTF8_FRAGMENT_BUFFER_TYPE) or
     (aBufferType = WEB_SOCKET_BINARY_FRAGMENT_BUFFER_TYPE) then
  begin
    // Fragment
    if not fProtocol.ManualFragmentManagement then
      PushFragmentIntoBuffer;
    if Assigned(fProtocol.OnFragment) then
      fProtocol.OnFragment(self, aBufferType, aBuffer, aBufferSize);
  end
  else
  begin
    // last Fragment
    if Assigned(fProtocol.OnMessage) then
    begin
      if fProtocol.ManualFragmentManagement then
        fProtocol.OnMessage(self, aBufferType, aBuffer, aBufferSize)
      else
      begin
        PushFragmentIntoBuffer;
        fProtocol.OnMessage(self, aBufferType, pointer(fBuffer), Length(fBuffer));
        fBuffer := '';
      end;
    end;
  end;
end;

procedure THttpApiWebSocketConnection.DoOnConnect;
begin
  if (fProtocol <> nil) and
     Assigned(fProtocol.OnConnect) then
    fProtocol.OnConnect(self);
end;

procedure THttpApiWebSocketConnection.DoOnDisconnect;
begin
  if (fProtocol <> nil) and
     Assigned(fProtocol.OnDisconnect) then
    fProtocol.OnDisconnect(self, fCloseStatus, pointer(fBuffer), length(fBuffer));
end;

function THttpApiWebSocketConnection.ReadData(const WebsocketBufferData): integer;
var
  err: HRESULT;
  read: cardinal;
  buf: WEB_SOCKET_BUFFER_DATA absolute WebsocketBufferData;
begin
  result := 0;
  if fWSHandle = nil then
    exit;
  err := Http.ReceiveRequestEntityBody(fProtocol.fServer.fReqQueue,
    fOpaqueHTTPRequestId, 0, buf.pbBuffer, buf.ulBufferLength, read,
    @self.fOverlapped);
  case err of
    // On page reload Safari do not send a WEB_SOCKET_INDICATE_RECEIVE_COMPLETE_ACTION
    // with BufferType = WEB_SOCKET_CLOSE_BUFFER_TYPE, instead it send a dummy packet
    // (WEB_SOCKET_RECEIVE_FROM_NETWORK_ACTION) and terminate socket
    // see forum discussion https://synopse.info/forum/viewtopic.php?pid=27125
    ERROR_HANDLE_EOF:
      result := -1;
    ERROR_IO_PENDING:
      ; //
    NO_ERROR:
      ; //
  else
    // todo: close connection?
  end;
end;

procedure THttpApiWebSocketConnection.WriteData(const WebsocketBufferData);
var
  err: HRESULT;
  inmem: HTTP_DATA_CHUNK_INMEMORY;
  writ: cardinal;
  buf: WEB_SOCKET_BUFFER_DATA absolute WebsocketBufferData;
begin
  if fWSHandle = nil then
    exit;
  writ := 0;
  inmem.DataChunkType := hctFromMemory;
  inmem.pBuffer := buf.pbBuffer;
  inmem.BufferLength := buf.ulBufferLength;
  err := Http.SendResponseEntityBody(fProtocol.fServer.fReqQueue,
    fOpaqueHTTPRequestId, HTTP_SEND_RESPONSE_FLAG_BUFFER_DATA or
    HTTP_SEND_RESPONSE_FLAG_MORE_DATA, 1, @inmem, writ, nil, nil,
    @fProtocol.fServer.fSendOverlaped);
  case err of
    ERROR_HANDLE_EOF:
      Disconnect;
    ERROR_IO_PENDING:
      ; //
    NO_ERROR:
      ; //
  else
    // todo: close connection?
  end;
end;

procedure THttpApiWebSocketConnection.CheckIsActive;
var
  elapsed: Int64;
begin
  if (fLastReceiveTickCount > 0) and
     (fProtocol.fServer.fPingTimeout > 0) then
  begin
    elapsed := mormot.core.os.GetTickCount64 - fLastReceiveTickCount;
    if elapsed > 2 * fProtocol.fServer.PingTimeout * 1000 then
    begin
      fProtocol.RemoveConnection(fIndex);
      fState := wsClosedByGuard;
      fCloseStatus := WEB_SOCKET_ENDPOINT_UNAVAILABLE_CLOSE_STATUS;
      fBuffer := 'Closed after ping timeout';
      IocpPostQueuedStatus(
        fProtocol.fServer.fThreadPoolServer.FRequestQueue, 0, nil, @fOverlapped);
    end
    else if elapsed >= fProtocol.fServer.PingTimeout * 1000 then
      Ping;
  end;
end;

procedure THttpApiWebSocketConnection.Disconnect;
var //Err: HRESULT; //todo: handle error
  chunk: HTTP_DATA_CHUNK_INMEMORY;
  writ: cardinal;
begin
  WebSocketApi.AbortHandle(fWSHandle);
  WebSocketApi.DeleteHandle(fWSHandle);
  fWSHandle := nil;
  chunk.DataChunkType := hctFromMemory;
  chunk.pBuffer := nil;
  chunk.BufferLength := 0;
  Http.SendResponseEntityBody(fProtocol.fServer.fReqQueue, fOpaqueHTTPRequestId,
    HTTP_SEND_RESPONSE_FLAG_DISCONNECT, 1, @chunk, writ, nil, nil, nil);
end;

procedure THttpApiWebSocketConnection.BeforeRead;
begin
  // if reading is in progress then try read messages else try receive new messages
  if fState in [wsOpen, wsClosing] then
  begin
    if Assigned(fLastActionContext) then
    begin
      EWebSocketApi.RaiseOnError(hCompleteAction,
        WebSocketApi.CompleteAction(fWSHandle, fLastActionContext,
        fOverlapped.InternalHigh));
      fLastActionContext := nil;
    end
    else
      EWebSocketApi.RaiseOnError(hReceive,
        WebSocketApi.Receive(fWSHandle, nil, nil));
  end
  else
    raise EWebSocketApi.CreateFmt(
      'THttpApiWebSocketConnection.BeforeRead state is not wsOpen (%d)',
      [ord(fState)]);
end;

const
  C_WEB_SOCKET_BUFFER_SIZE = 2;

type
  TWebSocketBufferDataArr = array[0..C_WEB_SOCKET_BUFFER_SIZE - 1] of WEB_SOCKET_BUFFER_DATA;

function THttpApiWebSocketConnection.ProcessActions(
  ActionQueue: WEB_SOCKET_ACTION_QUEUE): boolean;
var
  buf: TWebSocketBufferDataArr;
  bufcount: ULONG;
  buftyp: WEB_SOCKET_BUFFER_TYPE;
  action: WEB_SOCKET_ACTION;
  appctxt: pointer;
  actctxt: pointer;
  i: PtrInt;
  err: HRESULT;

  procedure CloseConnection;
  begin
    EnterCriticalSection(fProtocol.fSafe);
    try
      fProtocol.RemoveConnection(fIndex);
    finally
      LeaveCriticalSection(fProtocol.fSafe);
    end;
    EWebSocketApi.RaiseOnError(hCompleteAction,
      WebSocketApi.CompleteAction(fWSHandle, actctxt, 0));
  end;

begin
  result := true;
  repeat
    bufcount := Length(buf);
    EWebSocketApi.RaiseOnError(hGetAction,
      WebSocketApi.GetAction(fWSHandle, ActionQueue, @buf[0], bufcount,
      action, buftyp, appctxt, actctxt));
    case action of
      WEB_SOCKET_NO_ACTION:
        ;
      WEB_SOCKET_SEND_TO_NETWORK_ACTION:
        begin
          for i := 0 to bufcount - 1 do
            WriteData(buf[i]);
          if fWSHandle <> nil then
          begin
            err := WebSocketApi.CompleteAction(fWSHandle, actctxt, 0);
            EWebSocketApi.RaiseOnError(hCompleteAction, err);
          end;
          result := false;
          exit;
        end;
      WEB_SOCKET_INDICATE_SEND_COMPLETE_ACTION:
        ;
      WEB_SOCKET_RECEIVE_FROM_NETWORK_ACTION:
        begin
          for i := 0 to bufcount - 1 do
            if ReadData(buf[i]) = -1 then
            begin
              fState := wsClosedByClient;
              fBuffer := '';
              fCloseStatus := WEB_SOCKET_ENDPOINT_UNAVAILABLE_CLOSE_STATUS;
              CloseConnection;
            end;
          fLastActionContext := actctxt;
          result := false;
          exit;
        end;
      WEB_SOCKET_INDICATE_RECEIVE_COMPLETE_ACTION:
        begin
          fLastReceiveTickCount := mormot.core.os.GetTickCount64;
          if buftyp = WEB_SOCKET_CLOSE_BUFFER_TYPE then
          begin
            if fState = wsOpen then
              fState := wsClosedByClient
            else
              fState := wsClosedByServer;
            FastSetRawByteString(fBuffer, buf[0].pbBuffer, buf[0].ulBufferLength);
            fCloseStatus := buf[0].Reserved1;
            CloseConnection;
            result := false;
            exit;
          end
          else if buftyp = WEB_SOCKET_PING_PONG_BUFFER_TYPE then
          begin
            // todo: may be answer to client's ping
            EWebSocketApi.RaiseOnError(hCompleteAction,
              WebSocketApi.CompleteAction(fWSHandle, actctxt, 0));
            exit;
          end
          else if buftyp = WEB_SOCKET_UNSOLICITED_PONG_BUFFER_TYPE then
          begin
            // todo: may be handle this situation
            EWebSocketApi.RaiseOnError(hCompleteAction,
              WebSocketApi.CompleteAction(fWSHandle, actctxt, 0));
            exit;
          end
          else
          begin
            DoOnMessage(buftyp, buf[0].pbBuffer, buf[0].ulBufferLength);
            EWebSocketApi.RaiseOnError(hCompleteAction,
              WebSocketApi.CompleteAction(fWSHandle, actctxt, 0));
            exit;
          end;
        end
    else
      raise EWebSocketApi.CreateFmt('Invalid WebSocket action %d', [byte(action)]);
    end;
    err := WebSocketApi.CompleteAction(fWSHandle, actctxt, 0);
    if actctxt <> nil then
      EWebSocketApi.RaiseOnError(hCompleteAction, err);
  until {%H-}action = WEB_SOCKET_NO_ACTION;
end;

procedure THttpApiWebSocketConnection.InternalSend(
  aBufferType: WEB_SOCKET_BUFFER_TYPE; WebsocketBufferData: pointer);
begin
  EWebSocketApi.RaiseOnError(hSend,
    WebSocketApi.Send(fWSHandle, aBufferType, WebsocketBufferData, nil));
  ProcessActions(WEB_SOCKET_SEND_ACTION_QUEUE);
end;

procedure THttpApiWebSocketConnection.Send(aBufferType: WEB_SOCKET_BUFFER_TYPE;
  aBuffer: pointer; aBufferSize: ULONG);
var
  buf: WEB_SOCKET_BUFFER_DATA;
begin
  if fState <> wsOpen then
    exit;
  buf.pbBuffer := aBuffer;
  buf.ulBufferLength := aBufferSize;
  InternalSend(aBufferType, @buf);
end;

procedure THttpApiWebSocketConnection.Close(aStatus: WEB_SOCKET_CLOSE_STATUS;
  aBuffer: pointer; aBufferSize: ULONG);
var
  buf: WEB_SOCKET_BUFFER_DATA;
begin
  if fState = wsOpen then
    fState := wsClosing;
  buf.pbBuffer := aBuffer;
  buf.ulBufferLength := aBufferSize;
  buf.Reserved1 := aStatus;
  InternalSend(WEB_SOCKET_CLOSE_BUFFER_TYPE, @buf);
end;

procedure THttpApiWebSocketConnection.Ping;
begin
  InternalSend(WEB_SOCKET_PING_PONG_BUFFER_TYPE, nil);
end;


{ THttpApiWebSocketServer }

constructor THttpApiWebSocketServer.Create(
  aSocketThreadsCount, aPingTimeout: integer; const QueueName: SynUnicode;
  const aOnWSThreadStart, aOnWSThreadTerminate: TOnNotifyThread;
  ProcessOptions: THttpServerOptions);
begin
  inherited Create(QueueName, nil, nil, '', ProcessOptions);
  if not (WebSocketApi.WebSocketEnabled) then
    raise EWebSocketApi.Create('WebSocket API not supported');
  fPingTimeout := aPingTimeout;
  if fPingTimeout > 0 then
    fGuard := TSynWebSocketGuard.Create(Self);
  New(fRegisteredProtocols);
  SetLength(fRegisteredProtocols^, 0);
  FOnWSThreadStart := aOnWSThreadStart;
  FOnWSThreadTerminate := aOnWSThreadTerminate;
  fThreadPoolServer := TSynThreadPoolHttpApiWebSocketServer.Create(Self,
    aSocketThreadsCount);
end;

constructor THttpApiWebSocketServer.CreateClone(From: THttpApiServer);
var
  serv: THttpApiWebSocketServer absolute From;
begin
  inherited CreateClone(From);
  fThreadPoolServer := serv.fThreadPoolServer;
  fPingTimeout := serv.fPingTimeout;
  fRegisteredProtocols := serv.fRegisteredProtocols
end;

procedure THttpApiWebSocketServer.DestroyMainThread;
var
  i: PtrInt;
begin
  fGuard.Free;
  for i := 0 to Length(fRegisteredProtocols^) - 1 do
    fRegisteredProtocols^[i].doShutdown;
  FreeAndNilSafe(fThreadPoolServer);
  for i := 0 to Length(fRegisteredProtocols^) - 1 do
    fRegisteredProtocols^[i].Free;
  fRegisteredProtocols^ := nil;
  Dispose(fRegisteredProtocols);
  fRegisteredProtocols := nil;
  inherited;
end;

procedure THttpApiWebSocketServer.DoAfterResponse(Ctxt: THttpServerRequest;
  const Referer: RawUtf8; StatusCode: cardinal; Elapsed, Received, Sent: QWord);
begin
  if Assigned(fLastConnection) then
    IocpPostQueuedStatus(fThreadPoolServer.FRequestQueue, 0, nil,
      @fLastConnection.fOverlapped);
  inherited DoAfterResponse(Ctxt, Referer, StatusCode, Elapsed, Received, Sent);
end;

function THttpApiWebSocketServer.GetProtocol(index: integer):
  THttpApiWebSocketServerProtocol;
begin
  if cardinal(index) < cardinal(Length(fRegisteredProtocols^)) then
    result := fRegisteredProtocols^[index]
  else
    result := nil;
end;

function THttpApiWebSocketServer.GetProtocolsCount: integer;
begin
  if self = nil then
    result := 0
  else
    result := Length(fRegisteredProtocols^);
end;

function THttpApiWebSocketServer.GetSendResponseFlags(Ctxt: THttpServerRequest): integer;
begin
  if (PHTTP_REQUEST(Ctxt.HttpApiRequest)^.UrlContext = WEB_SOCKET_URL_CONTEXT) and
     (fLastConnection <> nil) then
    result := HTTP_SEND_RESPONSE_FLAG_OPAQUE or
      HTTP_SEND_RESPONSE_FLAG_MORE_DATA or HTTP_SEND_RESPONSE_FLAG_BUFFER_DATA
  else
    result := inherited GetSendResponseFlags(Ctxt);
end;

function THttpApiWebSocketServer.UpgradeToWebSocket(
  Ctxt: THttpServerRequestAbstract): cardinal;
var
  proto: THttpApiWebSocketServerProtocol;
  i, j: PtrInt;
  req: PHTTP_REQUEST;
  p: PHTTP_UNKNOWN_HEADER;
  ch, chB: PUtf8Char;
  protoname: RawUtf8;
  protofound: boolean;
label
  fnd;
begin
  result := 404;
  proto := nil;
  protofound := false;
  req := PHTTP_REQUEST((Ctxt as THttpServerRequest).HttpApiRequest);
  p := req^.headers.pUnknownHeaders;
  for j := 1 to req^.headers.UnknownHeaderCount do
  begin
    if (p.NameLength = Length(sProtocolHeader)) and
       IdemPChar(p.pName, pointer(sProtocolHeader)) then
    begin
      protofound := true;
      for i := 0 to Length(fRegisteredProtocols^) - 1 do
      begin
        ch := p.pRawValue;
        while (ch - p.pRawValue) < p.RawValueLength do
        begin
          while ((ch - p.pRawValue) < p.RawValueLength) and
                (ch^ in [',', ' ']) do
            inc(ch);
          chB := ch;
          while ((ch - p.pRawValue) < p.RawValueLength) and
                not (ch^ in [',']) do
            inc(ch);
          FastSetString(protoname, chB, ch - chB);
          if protoname = fRegisteredProtocols^[i].name then
          begin
            proto := fRegisteredProtocols^[i];
            goto fnd;
          end;
        end;
      end;
    end;
    inc(p);
  end;
  if not protofound and
     (proto = nil) and
     (Length(fRegisteredProtocols^) = 1) then
    proto := fRegisteredProtocols^[0];
fnd:
  if proto <> nil then
  begin
    EnterCriticalSection(proto.fSafe);
    try
      New(fLastConnection);
      if fLastConnection.TryAcceptConnection(
          proto, Ctxt, protofound) then
      begin
        proto.AddConnection(fLastConnection);
        result := 101
      end
      else
      begin
        Dispose(fLastConnection);
        fLastConnection := nil;
        result := HTTP_NOTALLOWED;
      end;
    finally
      LeaveCriticalSection(proto.fSafe);
    end;
  end;
end;

function THttpApiWebSocketServer.AddUrlWebSocket(const aRoot, aPort: RawUtf8;
  Https: boolean; const aDomainName: RawUtf8; aRegisterUri: boolean): integer;
begin
  result := AddUrl(
    aRoot, aPort, Https, aDomainName, aRegisterUri, WEB_SOCKET_URL_CONTEXT);
end;

procedure THttpApiWebSocketServer.RegisterProtocol(const aName: RawUtf8;
  aManualFragmentManagement: boolean;
  const aOnAccept: TOnHttpApiWebSocketServerAcceptEvent;
  const aOnMessage: TOnHttpApiWebSocketServerMessageEvent;
  const aOnConnect: TOnHttpApiWebSocketServerConnectEvent;
  const aOnDisconnect: TOnHttpApiWebSocketServerDisconnectEvent;
  const aOnFragment: TOnHttpApiWebSocketServerMessageEvent);
var
  protocol: THttpApiWebSocketServerProtocol;
begin
  if self = nil then
    exit;
  protocol := THttpApiWebSocketServerProtocol.Create(aName,
    aManualFragmentManagement, Self, aOnAccept, aOnMessage, aOnConnect,
    aOnDisconnect, aOnFragment);
  protocol.fIndex := length(fRegisteredProtocols^);
  SetLength(fRegisteredProtocols^, protocol.fIndex + 1);
  fRegisteredProtocols^[protocol.fIndex] := protocol;
end;

function THttpApiWebSocketServer.Request(
  Ctxt: THttpServerRequestAbstract): cardinal;
begin
  if PHTTP_REQUEST(THttpServerRequest(Ctxt).HttpApiRequest).
       UrlContext = WEB_SOCKET_URL_CONTEXT then
    result := UpgradeToWebSocket(Ctxt)
  else
  begin
    result := inherited Request(Ctxt);
    fLastConnection := nil;
  end;
end;

procedure THttpApiWebSocketServer.SendServiceMessage;
begin
  IocpPostQueuedStatus(fThreadPoolServer.FRequestQueue, 0, nil, @fServiceOverlaped);
end;

procedure THttpApiWebSocketServer.SetOnWSThreadStart(const Value: TOnNotifyThread);
begin
  FOnWSThreadStart := Value;
end;

procedure THttpApiWebSocketServer.SetOnWSThreadTerminate(const Value: TOnNotifyThread);
begin
  FOnWSThreadTerminate := Value;
end;


{ TSynThreadPoolHttpApiWebSocketServer }

function TSynThreadPoolHttpApiWebSocketServer.NeedStopOnIOError: boolean;
begin
  // If connection closed by guard than ERROR_HANDLE_EOF or ERROR_OPERATION_ABORTED
  // can be returned - Other connections must work normally
  result := false;
end;

procedure TSynThreadPoolHttpApiWebSocketServer.OnThreadStart(Sender: TThread);
begin
  if Assigned(fServer.OnWSThreadStart) then
    fServer.OnWSThreadStart(Sender);
end;

procedure TSynThreadPoolHttpApiWebSocketServer.OnThreadTerminate(Sender: TThread);
begin
  if Assigned(fServer.OnWSThreadTerminate) then
    fServer.OnWSThreadTerminate(Sender);
end;

procedure TSynThreadPoolHttpApiWebSocketServer.Task(
  aCaller: TSynThreadPoolWorkThread; aContext: pointer);
var
  conn: PHttpApiWebSocketConnection;
begin
  if aContext = @fServer.fSendOverlaped then
    exit;
  if aContext = @fServer.fServiceOverlaped then
  begin
    if Assigned(fServer.OnServiceMessage) then
      fServer.OnServiceMessage;
    exit;
  end;
  conn := PHttpApiWebSocketConnection(aContext);
  if conn.fState = wsConnecting then
  begin
    conn.fState := wsOpen;
    conn.fLastReceiveTickCount := mormot.core.os.GetTickCount64;
    conn.DoOnConnect();
  end;
  if conn.fState in [wsOpen, wsClosing] then
    repeat
      conn.BeforeRead;
    until not conn.ProcessActions(WEB_SOCKET_RECEIVE_ACTION_QUEUE);
  if conn.fState in [wsClosedByGuard] then
    EWebSocketApi.RaiseOnError(hCompleteAction,
      WebSocketApi.CompleteAction(conn.fWSHandle, conn.fLastActionContext, 0));
  if conn.fState in
       [wsClosedByClient, wsClosedByServer, wsClosedByGuard, wsClosedByShutdown] then
  begin
    conn.DoOnDisconnect;
    if conn.fState = wsClosedByClient then
      conn.Close(conn.fCloseStatus, pointer(conn.fBuffer), length(conn.fBuffer));
    conn.Disconnect;
    EnterCriticalSection(conn.Protocol.fSafe);
    try
      conn.Protocol.fPendingForClose.Remove(conn);
    finally
      LeaveCriticalSection(conn.Protocol.fSafe);
    end;
    Dispose(conn);
  end;
end;

constructor TSynThreadPoolHttpApiWebSocketServer.Create(Server:
  THttpApiWebSocketServer; NumberOfThreads: integer);
begin
  fServer := Server;
  fOnThreadStart := OnThreadStart;
  fOnThreadTerminate := OnThreadTerminate;
  inherited Create(NumberOfThreads, Server.fReqQueue);
end;


{ TSynWebSocketGuard }

procedure TSynWebSocketGuard.Execute;
var
  i, j: PtrInt;
  prot: THttpApiWebSocketServerProtocol;
begin
  if fServer.fPingTimeout > 0 then
    while not Terminated do
    begin
      if fServer <> nil then
        for i := 0 to Length(fServer.fRegisteredProtocols^) - 1 do
        begin
          prot := fServer.fRegisteredProtocols^[i];
          EnterCriticalSection(prot.fSafe);
          try
            for j := 0 to prot.fConnectionsCount - 1 do
              if Assigned(prot.fConnections[j]) then
                prot.fConnections[j].CheckIsActive;
          finally
            LeaveCriticalSection(prot.fSafe);
          end;
        end;
      i := 0;
      while not Terminated and
            (i < fServer.fPingTimeout) do
      begin
        Sleep(1000);
        inc(i);
      end;
    end
  else
    Terminate;
end;

constructor TSynWebSocketGuard.Create(Server: THttpApiWebSocketServer);
begin
  fServer := Server;
  inherited Create(false);
end;

{$endif USEWININET}

initialization
  assert(SizeOf(THttpPeerCacheMessage) = 192);

end.

