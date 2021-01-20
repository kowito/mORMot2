/// regression tests for RESTful ORM over Http or WebSockets
// - this unit is a part of the Open Source Synopse mORMot framework 2,
// licensed under a MPL/GPL/LGPL three license - see LICENSE.md
unit test.orm.network;

interface

{$I ..\src\mormot.defines.inc}

uses
  sysutils,
  contnrs,
  classes,
  mormot.core.base,
  mormot.core.os,
  mormot.core.text,
  mormot.core.buffers,
  mormot.core.unicode,
  mormot.core.datetime,
  mormot.core.rtti,
  mormot.core.crypto,
  mormot.core.data,
  mormot.core.variants,
  mormot.core.json,
  mormot.core.log,
  mormot.core.perf,
  mormot.core.search,
  mormot.core.mustache,
  mormot.core.test,
  mormot.core.interfaces,
  mormot.core.secure,
  mormot.core.jwt,
  mormot.net.client,
  mormot.net.server,
  mormot.net.relay,
  mormot.net.ws.core,
  mormot.net.ws.client,
  mormot.net.ws.server,
  mormot.db.core,
  mormot.db.nosql.bson,
  mormot.orm.core,
  mormot.orm.rest,
  mormot.orm.storage,
  mormot.orm.sqlite3,
  mormot.orm.client,
  mormot.orm.server,
  mormot.soa.core,
  mormot.soa.server,
  mormot.rest.core,
  mormot.rest.client,
  mormot.rest.server,
  mormot.rest.memserver,
  mormot.rest.sqlite3,
  mormot.rest.http.client,
  mormot.rest.http.server,
  mormot.db.raw.sqlite3,
  mormot.db.raw.sqlite3.static,
  test.core.data,
  test.core.base,
  test.orm.core,
  test.orm.sqlite3;

type
  /// this test case will test most functions, classes and types defined and
  // implemented in the mORMotSQLite3 unit, i.e. the SQLite3 engine itself,
  // used as a HTTP/1.1 server and client
  // - test a HTTP/1.1 server and client on the port 888 of the local machine
  // - require the 'test.db3' SQLite3 database file, as created by TTestFileBased
  TTestClientServerAccess = class(TSynTestCase)
  protected
    { these values are used internaly by the published methods below }
    Model: TOrmModel;
    DataBase: TRestServerDB;
    Server: TRestHttpServer;
    Client: TRestClientURI;
    /// perform the tests of the current Client instance
    procedure ClientTest;
    /// release used instances (e.g. http server) and memory
    procedure CleanUp; override;
  public
    /// this could be called as administrator for THttpApiServer to work
    {$ifdef MSWINDOWS}
    class function RegisterAddUrl(OnlyDelete: boolean): string;
    {$endif MSWINDOWS}
  published
    /// initialize a TRestHttpServer instance
    // - uses the 'test.db3' SQLite3 database file generated by TTestSQLite3Engine
    // - creates and validates a HTTP/1.1 server on the port 888 of the local
    // machine, using the THttpApiServer (using kernel mode http.sys) class
    // if available
    procedure _TRestHttpServer;
    /// validate the HTTP/1.1 client implementation
    // - by using a request of all records data
    procedure _TRestHttpClient;
    /// validate the HTTP/1.1 client multi-query implementation with one
    // connection for the all queries
    // - this method keep alive the HTTP connection, so is somewhat faster
    // - it runs 1000 remote SQL queries, and check the JSON data retrieved
    // - the time elapsed for this step is computed, and displayed on the report
    procedure HTTPClientKeepAlive;
    /// validate the HTTP/1.1 client multi-query implementation with one
    // connection initialized per query
    // - this method don't keep alive the HTTP connection, so is somewhat slower:
    // a new HTTP connection is created for every query
    // - it runs 1000 remote SQL queries, and check the JSON data retrieved
    // - the time elapsed for this step is computed, and displayed on the report
    procedure HTTPClientMultiConnect;
    {$ifndef PUREMORMOT2}
    /// validate the HTTP/1.1 client multi-query implementation with one
    // connection for the all queries and our proprietary SHA-256 / AES-256-CTR
    // encryption encoding
    // - it runs 1000 remote SQL queries, and check the JSON data retrieved
    // - the time elapsed for this step is computed, and displayed on the report
    procedure HTTPClientEncrypted;
    {$endif PUREMORMOT2}
    {$ifdef HASRESTCUSTOMENCRYPTION} // not fully safe -> not in mORMot 2
    /// validates TRest.SetCustomEncryption process with AES+SHA
    procedure HTTPClientCustomEncryptionAesSha;
    /// validates TRest.SetCustomEncryption process with only AES
    procedure HTTPClientCustomEncryptionAes;
    /// validates TRest.SetCustomEncryption process with only SHA
    procedure HTTPClientCustomEncryptionSha;
    {$endif HASRESTCUSTOMENCRYPTION}
    {$ifdef MSWINDOWSTODO}
    /// validate the Named-Pipe client implementation
    // - it first launch the Server as Named-Pipe
    // - it then runs 1000 remote SQL queries, and check the JSON data retrieved
    // - the time elapsed for this step is computed, and displayed on the report
    procedure NamedPipeAccess;
    /// validate the Windows Windows Messages based client implementation
    // - it first launch the Server to handle Windows Messages
    // - it then runs 1000 remote SQL queries, and check the JSON data retrieved
    // - the time elapsed for this step is computed, and displayed on the report
    procedure LocalWindowMessages;
    /// validate the client implementation, using direct access to the server
    // - it connects directly the client to the server, therefore use the same
    // process and memory during the run: it's the fastest possible way of
    // communicating
    // - it then runs 1000 remote SQL queries, and check the JSON data retrieved
    // - the time elapsed for this step is computed, and displayed on the report
    {$endif MSWINDOWS}
    procedure DirectInProcessAccess;
    /// validate HTTP/1.1 client-server with multiple TRestServer instances
    procedure HTTPSeveralDBServers;
  end;

implementation

{ TTestClientServerAccess }

procedure TTestClientServerAccess._TRestHttpClient;
var
  Resp: TOrmTable;
begin
  Client := TRestHttpClient.Create('127.0.0.1', HTTP_DEFAULTPORT, Model);
  fRunConsole := fRunConsole + 'using ' + string(Client.ClassName);
  (Client as TRestHttpClientGeneric).Compression := [];
  Resp := Client.Client.List([TOrmPeople], '*');
  if CheckFailed(Resp <> nil) then
    exit;
  try
    Check(Resp.InheritsFrom(TOrmTableJson));
    CheckEqual(Resp.RowCount, 11011);
    CheckHash(TOrmTableJson(Resp).PrivateInternalCopy, 4045204160);
    //FileFromString(TOrmTableJson(Resp).PrivateInternalCopy, 'internalfull2.parsed');
    //FileFromString(Resp.GetODSDocument, WorkDir + 'people.ods');
  finally
    Resp.Free;
  end;
end;

{$ifdef MSWINDOWS}

class function TTestClientServerAccess.RegisterAddUrl(OnlyDelete: boolean): string;
begin
  result := THttpApiServer.AddUrlAuthorize(
    'root', HTTP_DEFAULTPORT, false, '+', OnlyDelete);
end;
{$endif MSWINDOWS}

procedure TTestClientServerAccess._TRestHttpServer;
begin
  Model := TOrmModel.Create([TOrmPeople], 'root');
  Check(Model <> nil);
  Check(Model.GetTableIndex('people') >= 0);
  try
    DataBase := TRestServerDB.Create(Model, 'test.db3');
    DataBase.DB.Synchronous := smOff;
    DataBase.DB.LockingMode := lmExclusive;
    Server := TRestHttpServer.Create(HTTP_DEFAULTPORT, [DataBase], '+',
      HTTP_DEFAULT_MODE, 16, secSynShaAes);
    fRunConsole := fRunConsole + 'using ' + UTF8ToString(Server.HttpServer.APIVersion);
    Database.NoAjaxJson := true; // expect not expanded JSON from now on
  except
    on E: Exception do
      Check(false, E.Message);
  end;
end;

procedure TTestClientServerAccess.CleanUp;
begin
  FreeAndNil(Client); // should already be nil
  Server.Shutdown;
  FreeAndNil(Server);
  FreeAndNil(DataBase);
  FreeAndNil(Model);
end;

{$define WTIME}

const
  CLIENTTEST_WHERECLAUSE = 'FirstName Like "Sergei1%"';

procedure TTestClientServerAccess.ClientTest;
const
  IDTOUPDATE = 3;
{$ifdef WTIME}
  LOOP = 1000;
var
  Timer: ILocalPrecisionTimer;
{$else}
  LOOP = 100;
{$endif WTIME}
var
  i: integer;
  Resp: TOrmTable;
  Rec, Rec2: TOrmPeople;
  Refreshed: boolean;

  procedure TestOne;
  var
    i: integer;
  begin
    i := Rec.YearOfBirth;
    Rec.YearOfBirth := 1982;
    Check(Client.Orm.Update(Rec));
    Rec2.ClearProperties;
    Check(Client.Orm.Retrieve(IDTOUPDATE, Rec2));
    Check(Rec2.YearOfBirth = 1982);
    Rec.YearOfBirth := i;
    Check(Client.Orm.Update(Rec));
    if Client.InheritsFrom(TRestClientURI) then
    begin
      Check(Client.Client.UpdateFromServer([Rec2], Refreshed));
      Check(Refreshed, 'should have been refreshed');
    end
    else
      Check(Client.Orm.Retrieve(IDTOUPDATE, Rec2));
    Check(Rec.SameRecord(Rec2));
  end;

var
  onelen: integer;
begin
{$ifdef WTIME}
  Timer := TLocalPrecisionTimer.CreateAndStart;
{$endif WTIME}
  // first calc result: all transfert protocols have to work from cache
  Resp := Client.Client.List([TOrmPeople], '*', CLIENTTEST_WHERECLAUSE);
  if CheckFailed(Resp <> nil) then
    exit;
  CheckEqual(Resp.RowCount, 113);
  CheckHash(TOrmTableJson(Resp).PrivateInternalCopy, $8D727024);
  onelen := length(TOrmTableJson(Resp).PrivateInternalCopy);
  CheckEqual(onelen, 4818);
  Resp.Free;
{$ifdef WTIME}
  fRunConsole := format('%s%s, first %s, ', [fRunConsole, KB(onelen), Timer.Stop]);
{$endif WTIME}
  // test global connection speed and caching (both client and server sides)
  Rec2 := TOrmPeople.Create;
  Rec := TOrmPeople.Create(Client.Orm, IDTOUPDATE);
  try
    Check(Rec.ID = IDTOUPDATE, 'retrieve record');
    Check(Database.Orm.Cache.CachedEntries = 0);
    Check(Client.Orm.Cache.CachedEntries = 0);
    Check(Client.Orm.Cache.CachedMemory = 0);
    TestOne;
    Check(Client.Orm.Cache.CachedEntries = 0);
    Client.Orm.Cache.SetCache(TOrmPeople); // cache whole table
    Check(Client.Orm.Cache.CachedEntries = 0);
    Check(Client.Orm.Cache.CachedMemory = 0);
    TestOne;
    Check(Client.Orm.Cache.CachedEntries = 1);
    Check(Client.Orm.Cache.CachedMemory > 0);
    Client.Orm.Cache.Clear; // reset cache settings
    Check(Client.Orm.Cache.CachedEntries = 0);
    Client.Orm.Cache.SetCache(Rec); // cache one = SetCache(TOrmPeople,Rec.ID)
    Check(Client.Orm.Cache.CachedEntries = 0);
    Check(Client.Orm.Cache.CachedMemory = 0);
    TestOne;
    Check(Client.Orm.Cache.CachedEntries = 1);
    Check(Client.Orm.Cache.CachedMemory > 0);
    Client.Orm.Cache.SetCache(TOrmPeople);
    TestOne;
    Check(Client.Orm.Cache.CachedEntries = 1);
    Client.Orm.Cache.Clear;
    Check(Client.Orm.Cache.CachedEntries = 0);
    TestOne;
    Check(Client.Orm.Cache.CachedEntries = 0);
    if not (Client.InheritsFrom(TRestClientDB)) then
    begin // server-side
      Database.Orm.Cache.SetCache(TOrmPeople);
      TestOne;
      Check(Client.Orm.Cache.CachedEntries = 0);
      Check(Database.Orm.Cache.CachedEntries = 1);
      Database.Orm.Cache.Clear;
      Check(Client.Orm.Cache.CachedEntries = 0);
      Check(Database.Orm.Cache.CachedEntries = 0);
      Database.Orm.Cache.SetCache(TOrmPeople, Rec.ID);
      TestOne;
      Check(Client.Orm.Cache.CachedEntries = 0);
      Check(Database.Orm.Cache.CachedEntries = 1);
      Database.Orm.Cache.SetCache(TOrmPeople);
      Check(Database.Orm.Cache.CachedEntries = 0);
      TestOne;
      Check(Database.Orm.Cache.CachedEntries = 1);
      if Client.InheritsFrom(TRestClientURI) then
        Client.Client.ServerCacheFlush
      else
        Database.Orm.Cache.Flush;
      Check(Database.Orm.Cache.CachedEntries = 0);
      Check(Database.Orm.Cache.CachedMemory = 0);
      Database.Orm.Cache.Clear;
    end;
  finally
    Rec2.Free;
    Rec.Free;
  end;
  // test average speed for a 5 KB request
  Resp := Client.Client.List([TOrmPeople], '*', CLIENTTEST_WHERECLAUSE);
  Check(Resp <> nil);
  Resp.Free;
{$ifdef WTIME}
  Timer.Start;
{$endif}
  for i := 1 to LOOP do
  begin
    Resp := Client.Client.List([TOrmPeople], '*', CLIENTTEST_WHERECLAUSE);
    if CheckFailed(Resp <> nil) then
      exit;
    try
      Check(Resp.InheritsFrom(TOrmTableJson));
      // every answer contains 113 rows, for a total JSON size of 4803 bytes
      CheckEqual(Resp.RowCount, 113);
      CheckHash(TOrmTableJson(Resp).PrivateInternalCopy, $8D727024);
    finally
      Resp.Free;
    end;
  end;
{$ifdef WTIME}
  fRunConsole := format('%sdone %s i.e. %d/s, aver. %s, %s/s', [fRunConsole,
    Timer.Stop, Timer.PerSec(LOOP), Timer.ByCount(LOOP),
      KB(Timer.PerSec(onelen * (LOOP + 1)))]);
{$endif WTIME}
end;

procedure TTestClientServerAccess.HttpClientKeepAlive;
begin
  (Client as TRestHttpClientGeneric).KeepAliveMS := 20000;
  (Client as TRestHttpClientGeneric).Compression := [];
  ClientTest;
end;

procedure TTestClientServerAccess.HttpClientMultiConnect;
begin
  (Client as TRestHttpClientGeneric).KeepAliveMS := 0;
  (Client as TRestHttpClientGeneric).Compression := [];
  ClientTest;
end;

{$ifndef PUREMORMOT2}
procedure TTestClientServerAccess.HttpClientEncrypted;
begin
  (Client as TRestHttpClientGeneric).KeepAliveMS := 20000;
  (Client as TRestHttpClientGeneric).Compression := [hcSynShaAes];
  ClientTest;
end;
{$endif PUREMORMOT2}

{$ifdef HASRESTCUSTOMENCRYPTION}

procedure TTestClientServerAccess.HTTPClientCustomEncryptionAesSha;
var
  rnd: THash256;
  sign: TSynSigner;
begin
  TAESPRNG.Main.FillRandom(rnd);
  sign.Init(saSha256, 'secret1');
  Client.SetCustomEncryption(TAESOFB.Create(rnd), @sign, AlgoSynLZ);
  DataBase.SetCustomEncryption(TAESOFB.Create(rnd), @sign, AlgoSynLZ);
  ClientTest;
end;

procedure TTestClientServerAccess.HTTPClientCustomEncryptionAes;
var
  rnd: THash256;
begin
  TAESPRNG.Main.FillRandom(rnd);
  Client.SetCustomEncryption(TAESOFB.Create(rnd), nil, AlgoSynLZ);
  DataBase.SetCustomEncryption(TAESOFB.Create(rnd), nil, AlgoSynLZ);
  ClientTest;
end;

procedure TTestClientServerAccess.HTTPClientCustomEncryptionSha;
var
  sign: TSynSigner;
begin
  sign.Init(saSha256, 'secret2');
  Client.SetCustomEncryption(nil, @sign, AlgoSynLZ);
  DataBase.SetCustomEncryption(nil, @sign, AlgoSynLZ);
  ClientTest;
  Client.SetCustomEncryption(nil, nil, nil); // disable custom encryption
  DataBase.SetCustomEncryption(nil, nil, nil);
end;
{$endif HASRESTCUSTOMENCRYPTION}

procedure TTestClientServerAccess.HttpSeveralDBServers;
var
  Instance: array[0..2] of record
    Model: TOrmModel;
    Database: TRestServerDB;
    Client: TRestHttpClient;
  end;
  i: integer;
  Rec: TOrmPeople;
begin
  Rec := TOrmPeople.CreateAndFillPrepare(Database.Orm, CLIENTTEST_WHERECLAUSE);
  try
    Check(Rec.FillTable.RowCount = 113);
    // release main http client/server and main database instances
    CleanUp;
    assert(Client = nil);
    assert(Server = nil);
    assert(DataBase = nil);
    // create 3 TRestServerDB + TRestHttpClient instances (and TOrmModel)
    for i := 0 to high(Instance) do
      with Instance[i] do
      begin
        Model := TOrmModel.Create([TOrmPeople], 'root' + Int32ToUtf8(i));
        DataBase := TRestServerDB.Create(Model, SQLITE_MEMORY_DATABASE_NAME);
        Database.NoAjaxJson := true; // expect not expanded JSON from now on
        DataBase.Server.CreateMissingTables;
      end;
    // launch one HTTP server for all TRestServerDB instances
    Server := TRestHttpServer.Create(HTTP_DEFAULTPORT, [Instance[0].Database,
      Instance[1].Database, Instance[2].Database], '+', HTTP_DEFAULT_MODE, 4, secNone);
    // initialize the clients
    for i := 0 to high(Instance) do
      with Instance[i] do
        Client := TRestHttpClient.Create('127.0.0.1', HTTP_DEFAULTPORT, Model);
    // fill remotely all TRestServerDB instances
    for i := 0 to high(Instance) do
      with Instance[i] do
      begin
        Client.Client.TransactionBegin(TOrmPeople);
        Check(Rec.FillRewind);
        while Rec.FillOne do
          Check(Client.Client.Add(Rec, true, true) = Rec.IDValue);
        Client.Client.Commit;
      end;
    // test remote access to all TRestServerDB instances
    try
      for i := 0 to high(Instance) do
      begin
        Client := Instance[i].Client;
        DataBase := Instance[i].DataBase;
        try
          ClientTest;
          {$ifdef WTIME}
          if i < high(Instance) then
            fRunConsole := fRunConsole + #13#10 + '     ';
          {$endif WTIME}
        finally
          Client := nil;
          DataBase := nil;
        end;
      end;
    finally
      Client := nil;
      Database := nil;
      // release all TRestServerDB + TRestHttpClient instances (and TOrmModel)
      for i := high(Instance) downto 0 do
        with Instance[i] do
        begin
          FreeAndNil(Client);
          Server.RemoveServer(DataBase);
          FreeAndNil(DataBase);
          FreeAndNil(Model);
        end;
    end;
  finally
    Rec.Free;
  end;
end;

{$ifdef MSWINDOWSTODO}
procedure TTestClientServerAccess.NamedPipeAccess;
begin
  Check(DataBase.ExportServerNamedPipe('test'));
  Client.Free;
  Client := TRestClientURINamedPipe.Create(Model, 'test');
  ClientTest;
  // note: 1st connection is slower than with HTTP (about 100ms), because of
  // Sleep(128) in TRestServerNamedPipe.Execute: but we should connect
  // localy only once, and avoiding Context switching is a must-have
  FreeAndNil(Client);
  Check(DataBase.CloseServerNamedPipe);
end;

procedure TTestClientServerAccess.LocalWindowMessages;
begin
  Check(DataBase.ExportServerMessage('test'));
  Client := TRestClientURIMessage.Create(Model, 'test', 'Client', 1000);
  ClientTest;
  FreeAndNil(Client);
end;
{$endif MSWINDOWS}

procedure TTestClientServerAccess.DirectInProcessAccess;
var
  stats: RawUTF8;
begin
  FreeAndNil(Client);
  Client := TRestClientDB.Create(Model, TOrmModel.Create([TOrmPeople], 'root'),
    DataBase.DB, TRestServerTest);
  ClientTest;
  Client.CallBackGet('stat', ['withall', true], stats);
  FileFromString(JSONReformat(stats), WorkDir + 'statsClientServer.json');
  FreeAndNil(Client);
end;

end.

