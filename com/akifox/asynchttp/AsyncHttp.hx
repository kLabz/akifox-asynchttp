package com.akifox.asynchttp;

/**

@author Simone Cingano (yupswing) [Akifox Studio](http://akifox.com)

@licence MIT Licence

@version 0.4.0
[Public repository](https://github.com/yupswing/akifox-asynchttp/)

#### Asyncronous HTTP+HTTPS Request HAXE Library
The akifox-asynchttp library provide a multi-threaded tool
to handle HTTP+HTTPS requests with a common API.

#### Notes:
 * Inspired by Raivof "OpenFL: URLLoader() alternative using raw socket"
 * https://gist.github.com/raivof/dcdb1d74f93d17132a1e
 */

import haxe.Timer;
import haxe.io.Bytes;

using StringTools;

#if flash

	// Standard Flash URLLoader
	import flash.net.URLLoader;
	import flash.net.URLLoaderDataFormat;
	import flash.net.URLRequest;
	import flash.net.URLRequestHeader;
	import flash.events.Event;
	import flash.events.HTTPStatusEvent;
	import flash.events.SecurityErrorEvent;
	import flash.events.IOErrorEvent;

#elseif js

	// Standard Haxe Http
	import haxe.Http;

#elseif (neko || cpp || java)

	// Threading
	#if neko
		typedef Thread = neko.vm.Thread;
		typedef Lib = neko.Lib;
	#elseif java
		typedef Thread = java.vm.Thread;
		typedef Lib = java.Lib;
	#elseif cpp
		typedef Thread = cpp.vm.Thread;
		typedef Lib = cpp.Lib;
	#end

	// Sockets
	typedef AbstractSocket = {
		var input(default,null) : haxe.io.Input;
		var output(default,null) : haxe.io.Output;
		function connect( host : Host, port : Int ) : Void;
		function setTimeout( t : Float ) : Void;
		function write( str : String ) : Void;
		function close() : Void;
		function shutdown( read : Bool, write : Bool ) : Void;
	}

	// TCP Socket
	typedef SocketTCP = sys.net.Socket;

	// TCP+SSL Socket
	#if php
	typedef SocketSSL = php.net.SslSocket;
	#elseif java
	typedef SocketSSL = java.net.SslSocket;
	#elseif hxssl
		// #if neko
		// typedef SocketSSL = neko.tls.Socket;
		// #else
		typedef SocketSSL = sys.ssl.Socket;
		// #end
	#else
	typedef SocketSSL = sys.net.Socket; // NO SSL (fallback to HTTP Socket)
	#end

	// Host
	typedef Host = sys.net.Host;

	// Used by httpViaSocketConnect() to exchange data with httpViaSocket()
	typedef Requester = {
		var status:Int;
		var headers:HttpHeaders;
		var socket:AbstractSocket;
	}

#else

	#error "Platform not supported (yet!)\n
	Post a request to the official repository:\n
	https://github.com/yupswing/akifox-asynchttp/issues"

#end

enum HttpTransferMode {
  UNDEFINED;
  FIXED;
  CHUNKED;
}

enum ContentKind {
	XML;
	JSON;
	IMAGE;
	TEXT; //generic text type
	BYTES; //generic binary type
}

typedef ContentKindMatch = {
	var kind:ContentKind;
	var regex:EReg;
}

// DEPRECATED Kept for 0.1.x to 0.3.x compatibility
typedef AsyncHttpResponse = HttpResponse;
typedef AsyncHttpRequest = HttpRequest;

class AsyncHttp
{

	// ==========================================================================================

	// Global settings (customisable)
	public static var logEnabled:Bool = #if debug true #else false #end;
	public static var errorSafe:Bool = #if debug false #else true #end;
	public static var userAgent:String = "akifox-asynchttp";
	public static var maxRedirections:Int = 10;

	// ==========================================================================================

	// Logging trace (enabled by default on -debug)
	public static inline function log(message:String) {
		if (AsyncHttp.logEnabled) trace(message);
	}

	// Error trace (throw by default on -debug)
	// NOTE: to be error-safe it only make traces if not -debug
	public static inline function error(message:String) {
		if (AsyncHttp.errorSafe) {
			trace(message);
		} else {
			throw message;
		}
	}

	// ==========================================================================================

	public function new()
	{
		// One instance every Request.send() to be thread-safe
	}

	// ==========================================================================================


	public function send(request:HttpRequest) {

		if (request.finalised) {
			error('${request.fingerprint} ERROR: Unable to send the request: it was already sent before\n'+
																		'To send it again you have to clone it before.');
			return;
		}

		request.finalise(); // request will not change

		#if (neko || cpp || java)

			if (request.async) {
				// Asynchronous (with a new thread)
				var worker = Thread.create(httpViaSocket_Threaded);
				worker.sendMessage(request);
			} else {
				// Synchronous (same thread)
				httpViaSocket(request);
			}

		#elseif flash

			// URLLoader version (FLASH)
			httpViaUrlLoader(request);

		#elseif js

			// Standard Haxe HTTP
			httpViaHaxeHttp(request);

		#end

	}

	#if (neko || cpp || java)

	// ==========================================================================================
	// Multi-thread version for neko, CPP + JAVA

	private function httpViaSocket_Threaded() {
		var request:HttpRequest = Thread.readMessage(true);
		httpViaSocket(request);
	}

	// Open a socket, send a request and get the headers
	// (could be called more than once in case of redirects)
	private function httpViaSocketConnect(url:URL,request:HttpRequest):Requester {

		var headers = new HttpHeaders();
		var status:Int = 0;

		var s:AbstractSocket;
		if (url.ssl) {
			s = new SocketSSL();
			#if (!php && !java && !hxssl)
			error('${request.fingerprint} ERROR: requested HTTPS but no SSL support (fallback on HTTP)\n'+
																		'On Neko/CPP the library supports hxssl (you have to install and reference it with `-lib hxssl`');
			#end
		} else {
			s = new SocketTCP();
		}
		s.setTimeout(request.timeout);

		// -- START REQUEST

		var connected = false;
		log('${request.fingerprint} INFO: Request\n> ${request.method} ${url}');
		try {
			#if flash
			s.connect(url.host, url.port);
			#else
			s.connect(new Host(url.host), url.port);
			#end
			connected = true;
		} catch (msg:Dynamic) {
		  error('${request.fingerprint} ERROR: Request failed -> $msg');
		}

		if (connected) {

			var httpVersion = "1.1";
			if (!request.http11) httpVersion = "1.0";

			try {
				s.output.writeString('${request.method} ${url.resource}${url.querystring} HTTP/$httpVersion\r\n');
				log('${request.fingerprint} HTTP > ${request.method} ${url.resource}${url.querystring} HTTP/$httpVersion');
				s.output.writeString('User-Agent: $userAgent\r\n');
				log('${request.fingerprint} HTTP > User-Agent: $userAgent');
				s.output.writeString('Host: ${url.host}\r\n');
				log('${request.fingerprint} HTTP > Host: ${url.host}');

				if (request.headers!=null) {
					//custom headers
					for (key in request.headers.keys()) {
						var value = request.headers.get(key);
						if (HttpHeaders.validateRequest(key)) {
							s.output.writeString('$key: $value\r\n');
							log('${request.fingerprint} HTTP > $key: $value');
						}
					}
				}

				if (request.content!=null) {
					s.output.writeString('Content-Type: ${request.contentType}\r\n');
					log('${request.fingerprint} HTTP > Content-Type: ${request.contentType}');
					s.output.writeString('Content-Length: '+request.content.length+'\r\n');
					log('${request.fingerprint} HTTP > Content-Length: '+request.content.length);
					s.output.writeString('\r\n');
					if (request.contentIsBinary) {
						s.output.writeBytes(cast(request.content,Bytes),0,request.content.length);
					} else {
						s.output.writeString(request.content.toString());
					}
				}
				s.output.writeString('\r\n');
			} catch (msg:Dynamic) {
				error('${request.fingerprint} ERROR: Request failed -> $msg');
				status = 0;
				s.close();
				s = null;
				headers = new HttpHeaders();
				connected = false;
			}

		} // -- END REQUEST

		// -- START RESPONSE
		if (connected) {
			var ln:String = '';
			while (true)
			{
				try {
					ln = s.input.readLine().trim();
				} catch(msg:Dynamic) {
					// error (probably unexpected connection terminated)
					error('${request.fingerprint} ERROR: Transfer failed -> $msg');
					ln = '';
					status = 0;
					s.close();
					s = null;
					headers = new HttpHeaders();
					connected = false;
				}
				if (ln == '') break; //end of response headers

				if (status==0) {
					var r = ~/^HTTP\/\d+\.\d+ (\d+)/;
					r.match(ln);
					status = Std.parseInt(r.matched(1));
				} else {
					var a = ln.split(':');
					var key = a.shift().toLowerCase();
					headers.add(key,a.join(':').trim());
				}
		  }
		  // -- END RESPONSE HEADERS
		}

		return {status:status,socket:s,headers:headers};
	}

	// Ask httpViaSocketConnect to open a socket and send the request
	// then parse the response and handle it to the callback
	private function httpViaSocket(request:HttpRequest)
	{
		if (request==null) return;

		var start = Timer.stamp();

		// RESPONSE
		var url:URL=request.url;
		var content:Dynamic=null;
		var contentType:String=null;
		var contentLength:Int=0;
		var contentIsBinary:Bool=false;
		var filename:String = DEFAULT_FILENAME;

		var connected:Bool = false;
		var redirect:Bool = false;

		var s:AbstractSocket;
		var headers = new HttpHeaders();
		var status:Int = 0;

		// redirects url list to avoid loops
		var redirectChain = new Array<String>();
		redirectChain.push(url.toString());

		do {
			var req:Requester = httpViaSocketConnect(url,request);
			status = req.status;
			s = req.socket;
			headers = req.headers;
			req = null;

			connected = (status!=0);
			redirect = false;

			if (connected) {
				redirect = (status == 301 || status == 302 || status == 303 || status == 307);
				// determine if redirection
			  	if (redirect) {
			  		var newlocation = headers.get('location');
			  		if (newlocation != "") {
							var newURL = new URL(newlocation);
							newURL.merge(url);
			  			if (redirectChain.length<=maxRedirections && redirectChain.indexOf(newURL.toString())==-1) {
								url = newURL;
								redirectChain.push(url.toString());
								log('${request.fingerprint} REDIRECT: $status -> ${url}');
								s.close();
								s = null;
			  			} else {
			  				// redirect loop
			  				redirect = false;
								s.close();
								s = null;
								connected = false;
								if (redirectChain.length>maxRedirections) {
									error('${request.fingerprint} ERROR: Too many redirection (Max $maxRedirections)\n'+redirectChain.join('-->'));
								} else {
									error('${request.fingerprint} ERROR: Redirection loop\n'+redirectChain.join('-->')+'-->'+redirectChain[0]);
								}

			  			}
			  		}
			    }
			}
		} while(redirect);

		if (connected) {

			filename = determineFilename(url.toString());

			// -- START RESPONSE CONTENT

		  	// determine content properties
			contentLength = Std.parseInt(headers.get('content-length'));
			contentType = determineContentType(headers);
			var contentKind:ContentKind = determineContentKind(contentType);
			contentIsBinary = determineBinary(contentKind);

			// determine transfer mode
			var mode:HttpTransferMode = HttpTransferMode.UNDEFINED;
			if (contentLength>0) mode = HttpTransferMode.FIXED;
			if (headers.get('transfer-encoding') == 'chunked') mode = HttpTransferMode.CHUNKED;
			log('${request.fingerprint} TRANSFER MODE: $mode');

			var bytes_loaded:Int = 0;
			var contentBytes:Bytes=null;

			switch(mode) {
				case HttpTransferMode.UNDEFINED:

					// UNKNOWN CONTENT LENGTH

					try {
						contentBytes = s.input.readAll();
					} catch(msg:Dynamic) {
						error('${request.fingerprint} ERROR: Transfer failed -> $msg');
						status = 0;
						contentBytes = Bytes.alloc(0);
					}
					contentLength = contentBytes.length;
				  log('${request.fingerprint} LOADED: $contentLength/$contentLength bytes (100%)');

				case HttpTransferMode.FIXED:

					// KNOWN CONTENT LENGTH

			    contentBytes = Bytes.alloc(contentLength);
			    var block_len = 1024 * 1024;   // BLOCK SIZE: small value (like 64 KB) causes slow download
			    var nblocks = Math.ceil(contentLength / block_len);
			    var bytes_left = contentLength;
			    bytes_loaded = 0;

			    for (i in 0...nblocks)
			    {
			      var actual_block_len = (bytes_left > block_len) ? block_len : bytes_left;
						try {
				      s.input.readFullBytes(contentBytes, bytes_loaded, actual_block_len);
						} catch(msg:Dynamic) {
							error('${request.fingerprint} ERROR: Transfer failed -> $msg');
							status = 0;
							contentBytes = Bytes.alloc(0);
							break;
						}
			      bytes_left -= actual_block_len;

			      bytes_loaded += actual_block_len;
			      log('${request.fingerprint} LOADED: $bytes_loaded/$contentLength bytes (' + Math.round(bytes_loaded / contentLength * 1000) / 10 + '%)');
			    }

				case HttpTransferMode.CHUNKED:

					// CHUNKED MODE

					var bytes:Bytes;
					var buffer = new haxe.io.BytesBuffer();
					var chunk:Int;
					try {
						while(true) {
							var v:String = s.input.readLine();
							chunk = Std.parseInt('0x$v');
							if (chunk==0) break;
							bytes = s.input.read(chunk);
							bytes_loaded += chunk;
							buffer.add(bytes);
							s.input.read(2); // \n\r between chunks = 2 bytes
							log('${request.fingerprint} LOADED: $bytes_loaded bytes (Total unknown)');
						}
					} catch(msg:Dynamic) {
						error('${request.fingerprint} ERROR: Transfer failed -> $msg');
						status = 0;
						buffer = new haxe.io.BytesBuffer();
					}

					contentBytes = buffer.getBytes();
					contentLength = bytes_loaded;

					buffer = null;
					bytes = null;
			}

			// The response content is always given in bytes and handled by the HttpResponse object
			content = contentBytes;
			contentBytes = null;

		  // -- END RESPONSE

		}

		if (s!=null) {
			if (connected) s.close();
			s = null;
		}

		var time:Float = elapsedTime(start);

		log('${request.fingerprint} INFO: Response $status ($contentLength bytes in $time s)\n> ${request.method} $url');
		if (request.callback!=null) {
				headers.finalise(); // makes the headers object immutable
		    request.callback(new HttpResponse(request,time,url,headers,status,content,contentIsBinary,filename));
		}
  }

  #elseif flash

	// ==========================================================================================
	// URLLoader version (FLASH)

	// Convert from the Flash format
	private function convertFromFlashHeaders(urlLoaderHeaders:Array<Dynamic>):HttpHeaders {
		var headers = new HttpHeaders();
		if (urlLoaderHeaders!=null) {
			for (el in urlLoaderHeaders) {
				headers.add(el.name.trim().toLowerCase(),el.value);
			}
		}
		headers.finalise(); // makes the headers object immutable
		return headers;
	}

	private function convertToFlashHeaders(httpHeaders:HttpHeaders):Array<Dynamic> {
		var headers = new Array<URLRequestHeader>();
		if (httpHeaders!=null) {
			for (key in httpHeaders.keys()) {
				var value = httpHeaders.get(key);
				if (HttpHeaders.validateRequest(key)) {
					headers.push(new URLRequestHeader(key,value));
				}
			}
		}
		return headers;
	}

	private function httpViaUrlLoader(request:HttpRequest) {
		if (request==null) return;

		var urlLoader:URLLoader = new URLLoader();
		var start = Timer.stamp();

		// RESPONSE FIELDS
		var url:URL = request.url;
		var status:Int = 0;
		var headers = new HttpHeaders();
		headers.finalise(); // makes the headers object immutable
		var content:Dynamic = null;

		var contentType:String = DEFAULT_CONTENT_TYPE;
		var contentIsBinary:Bool = determineBinary(determineContentKind(contentType));

		var filename:String = determineFilename(request.url.toString());
		urlLoader.dataFormat = (contentIsBinary?URLLoaderDataFormat.BINARY:URLLoaderDataFormat.TEXT);

		log('${request.fingerprint} INFO: Request\n> ${request.method} ${request.url}');

		var urlRequest = new URLRequest(request.url.toString());
		urlRequest.method = request.method;
		if (request.content!=null && request.method != HttpMethod.GET) {
			urlRequest.data = request.content;
			urlRequest.contentType = request.contentType;
			//urlRequest.dataFormat = (request.contentIsBinary?URLLoaderDataFormat.BINARY:URLLoaderDataFormat.TEXT);
		}

		// if (request.headers!=null) { // TODO check if supported (it looks only on POST and limited)
		// 	// custom headers
		// 	urlRequest.requestHeaders = convertToFlashHeaders(request.headers);
		// }

		var httpstatusDone = false;

		urlLoader.addEventListener("httpStatus", function(e:HTTPStatusEvent) {
			status = e.status;
		    log('${request.fingerprint} INFO: Response HTTP_Status $status');
			//content = null; // content will be retrive in EVENT.COMPLETE
			filename = determineFilename(url.toString());
			urlLoader.dataFormat = (contentIsBinary?URLLoaderDataFormat.BINARY:URLLoaderDataFormat.TEXT);
			httpstatusDone = true; //flash does not call this event
		});

		urlLoader.addEventListener("httpResponseStatus", function(e:HTTPStatusEvent) {
			var newUrl:URL = new URL(e.responseURL);
			newUrl.merge(request.url);
			url = newUrl;
			status = e.status;
		    log('${request.fingerprint} INFO: Response HTTP_Response_Status $status');
			try { headers = convertFromFlashHeaders(e.responseHeaders); }
			//content = null; // content will be retrive in EVENT.COMPLETE
			contentType = determineContentType(headers);
			contentIsBinary = determineBinary(determineContentKind(contentType));
			filename = determineFilename(url.toString());

			urlLoader.dataFormat = (contentIsBinary?URLLoaderDataFormat.BINARY:URLLoaderDataFormat.TEXT);
			httpstatusDone = true; //flash does not call this event
		});

		urlLoader.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent) {
		    var time = elapsedTime(start);
		    status = e.errorID;
		    error('${request.fingerprint} INFO: Response Error ' + e.errorID + ' ($time s)\n> ${request.method} ${request.url}');
		    if (request.callback!=null)
		    	request.callback(new HttpResponse(request,time,url,headers,status,content,contentIsBinary,filename));
		    urlLoader = null;
		});

		urlLoader.addEventListener(SecurityErrorEvent.SECURITY_ERROR, function(e:SecurityErrorEvent) {
		    var time = elapsedTime(start);
		    status = 0;
		    error('${request.fingerprint} INFO: Response Security Error ($time s)\n> ${request.method} ${request.url}');
		    if (request.callback!=null)
		    	request.callback(new HttpResponse(request,time,url,headers,status,content,contentIsBinary,filename));
		    urlLoader = null;
		});

		urlLoader.addEventListener(Event.COMPLETE, function(e:Event) {
			if (!httpstatusDone) status = 200;

		    var time = elapsedTime(start);
		    content = Bytes.ofString(e.target.data);
		    log('${request.fingerprint} INFO: Response Complete $status ($time s)\n> ${request.method} ${request.url}');
		    if (request.callback!=null)
		    	request.callback(new HttpResponse(request,time,url,headers,status,content,contentIsBinary,filename));
		    urlLoader = null;
		});

		try {
		  	urlLoader.load(urlRequest);
		} catch (msg:Dynamic) {
		    var time = elapsedTime(start);
		    error('${request.fingerprint} ERROR: Request failed -> $msg');
		    if (request.callback!=null)
		    	request.callback(new HttpResponse(request,time,url,headers,status,content,contentIsBinary,filename));
		    urlLoader = null;
		}
	}

	#elseif js

	private function httpViaHaxeHttp(request:HttpRequest) {
		if (request==null) return;
		var start = Timer.stamp();

		// RESPONSE FIELDS
		var url:URL = request.url;
		var status:Int = 0;
		var headers = new HttpHeaders();
		headers.finalise(); // makes the headers object immutable
		var content:Dynamic = null;

		var contentType:String = DEFAULT_CONTENT_TYPE;
		var contentIsBinary:Bool = determineBinary(determineContentKind(contentType));

		var filename:String = determineFilename(url.toString());

		var r = new haxe.Http(url.toString());
		r.async = true; //default
		//r.setHeader("User-Agent",USER_AGENT); //give warning in Chrome
		if (request.content!=null) {
			r.setPostData(Std.string(request.content));
		}

		var httpstatusDone = false;

		r.onError = function(msg:String) {
	    	error('${request.fingerprint} ERROR: Request failed -> $msg');
	    	var time = elapsedTime(start);
	    	if (request.callback!=null)
	    		request.callback(new HttpResponse(request,time,url,headers,status,content,contentIsBinary,filename));
		};

		r.onData = function(data:String) {
			if (!httpstatusDone) status = 200;
	    	var time = elapsedTime(start);
	    	content = data;
	    	log('${request.fingerprint} INFO: Response Complete $status ($time s)\n> ${request.method} ${request.url}');
	    	if (request.callback!=null)
	    		request.callback(new HttpResponse(request,time,url,headers,status,content,contentIsBinary,filename));
		};

		r.onStatus = function(http_status:Int) {
			status = http_status;
		    log('${request.fingerprint} INFO: Response HTTP Status $status');
			httpstatusDone = true; //flash does not call this event
		}

		r.request(request.content!=null);
	}

	#end

	// ==========================================================================================

	public function elapsedTime(start:Float):Float {
		return Std.int((Timer.stamp() - start)*1000)/1000;
	}

	// ==========================================================================================

	#if js
	public static inline var DEFAULT_CONTENT_TYPE = "text/plain";
	#else
	public static inline var DEFAULT_CONTENT_TYPE = "application/octet-stream";
	#end
	public static inline var DEFAULT_FILENAME = "untitled";

	private static var _contentKindMatch:Array<ContentKindMatch> = [
		{kind:ContentKind.IMAGE,regex:~/^image\/(jpe?g|png|gif)/i},
		{kind:ContentKind.XML,regex:~/(application\/xml|text\/xml|\+xml)/i},
		{kind:ContentKind.JSON,regex:~/^(application\/json|\+json)/i},
		{kind:ContentKind.TEXT,regex:~/(^text|application\/javascript)/i} //text is the last one
	];

	// The content kind is used for autoParsing and determine if a content is Binary or Text
	public function determineContentKind(contentType:String):ContentKind {
		var contentKind = ContentKind.BYTES;
		for (el in _contentKindMatch) {
			if (el.regex.match(contentType)) {
				contentKind = el.kind;
				break;
			}
		}
		return contentKind;
	}

	public function determineBinary(contentKind:ContentKind):Bool {
		if (contentKind == ContentKind.BYTES || contentKind == ContentKind.IMAGE) return true;
		return false;
	}

	public function determineContentType(headers:HttpHeaders):String {
		var contentType = DEFAULT_CONTENT_TYPE;
		if (headers!=null) {
			if (headers.exists('content-type')) contentType = headers.get('content-type');
		}
		return contentType;
	}

	public function determineFilename(url:String):String {
		var filename:String = "";
		var rx = ~/([^?\/]*)($|\?.*)/;
		if (rx.match(url)) {
			filename = rx.matched(1);
		}
		if (filename=="") filename = AsyncHttp.DEFAULT_FILENAME;
		return filename;
	}

	// ==========================================================================================

	//##########################################################################################
	//
	// UID Generator
	//
	//##########################################################################################

	private static var UID_CHARS = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";

	public function randomUID(?size:Int=32):String
	{
		var nchars = UID_CHARS.length;
		var uid = new StringBuf();
		for (i in 0 ... size){
			uid.addChar(UID_CHARS.charCodeAt( Std.random(nchars) ));
		}
		return uid.toString();
	}

}
