//
//  DNSResolver.swift
//  Burrow
//
//  Created by Jaden Geller on 5/28/16.
//
//

import DNSServiceDiscovery
import Logger

extension Logger { public static let dnsResolverCategory = "DNSResolver" }
private let log = Logger.category(Logger.dnsResolverCategory)

enum DNSResolveError: ErrorType {
    case queryFailure(DNSServiceErrorCode)
    case parseFailure(NSData)
}

private struct QueryInfo {
    var service: DNSServiceRef
    var socket: CFSocketRef!
    var runLoopSource: CFRunLoopSourceRef!
    var records: [Result<TXTRecord>]
    var responseHandler: Result<[TXTRecord]> -> ()
}

private func queryCallback(
    sdref: DNSServiceRef,
    flags: DNSServiceFlags,
    interfaceIndex: UInt32,
    errorCode: DNSServiceErrorType,
    fullname: UnsafePointer<Int8>,
    rrtype: UInt16,
    rrclass: UInt16,
    rdlen: UInt16,
    rdata: UnsafePointer<Void>,
    ttl: UInt32,
    context: UnsafeMutablePointer<Void>
) {
    log.debug("Callback for query \(sdref)")
    let queryContext = UnsafeMutablePointer<QueryInfo>(context)
    
    // Append record rresult
    queryContext.memory.records.append(Result {
        
        // Parse the TXT record
        let txtBuffer = UnsafeBufferPointer<UInt8>(start: UnsafePointer(rdata), count: Int(rdlen))
        guard let txtRecord = TXTRecord(buffer: txtBuffer) else {
            throw DNSResolveError.parseFailure(NSData(bytes: rdata, length: Int(rdlen)))
        }
        
        log.info("Received TXT record \(txtRecord) from domain \(String(CString: UnsafePointer(fullname), encoding: NSUTF8StringEncoding))")
        return txtRecord
    })
}

private func querySocketCallback(
    socket: CFSocket!,
    callbackType: CFSocketCallBackType,
    address: CFData!,
    data: UnsafePointer<Void>,
    info: UnsafeMutablePointer<Void>
) {
    assert(callbackType == .ReadCallBack)
    log.verbose("Callback of type \(callbackType) on socket: \(socket)")
    let queryContext = UnsafeMutablePointer<QueryInfo>(info)
    log.verbose("Current context is \(queryContext.memory)")
    assert(socket === queryContext.memory.socket)
    
    // Clean up resources
    defer {
        log.verbose("Cleaning up resources for query with socket: \(socket)")
        
        // Remove socket listener from run look, destory socket, and deallocate service
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), queryContext.memory.runLoopSource, kCFRunLoopDefaultMode)
        CFSocketInvalidate(queryContext.memory.socket)
        DNSServiceRefDeallocate(queryContext.memory.service)
        
        // Deallocate context info
        queryContext.destroy()
        queryContext.dealloc(1)
        
        // TODO: Is stuff leaking?
    }
    
    // Process the result
    log.verbose("Processing result for socket: \(socket)")
    let status = DNSServiceProcessResult(queryContext.memory.service)
    
    // Respond to the caller
    queryContext.memory.responseHandler(Result {
        if let errorCode = DNSServiceErrorCode(rawValue: Int(status)) {
            throw DNSResolveError.queryFailure(errorCode)
        } else {
            return try queryContext.memory.records.map { try $0.unwrap() }
        }
    })
}

class DNSResolver {
    private init() { }
    
    /// Query a domain's TXT records asynchronously
    static func resolveTXT(domain: Domain, responseHandler: Result<[TXTRecord]> -> ()) throws {
        log.debug("Will resolve domain `\(domain)`")
        
        // Create space on the heap for the context
        let queryContext = UnsafeMutablePointer<QueryInfo>.alloc(1)
        queryContext.initialize(QueryInfo(
            service: nil,
            socket: nil,
            runLoopSource: nil,
            records: [],
            responseHandler: responseHandler
        ))
        
        // Create DNS Query
        var service: DNSServiceRef = nil
        let status = String(domain).withCString { fullname in
            DNSServiceQueryRecord(
                /* serviceRef: */ &service,
                /* flags: */ 0,
                /* interfaceIndex: */ 0,
                /* fullname: */ fullname,
                /* rrtype: */ UInt16(kDNSServiceType_TXT),
                /* rrclass: */ UInt16(kDNSServiceClass_IN),
                /* callback: */ queryCallback,
                /* context: */ queryContext
            )
        }
        if let errorCode = DNSServiceErrorCode(rawValue: Int(status)) {
            throw DNSResolveError.queryFailure(errorCode)
        }
        
        assert(service != nil)
        queryContext.memory.service = service
        log.verbose("Created DNS query \(service) to domain `\(domain)`")
        
        // Create socket to query
        var socketContext = CFSocketContext(
            version: 0,
            info: queryContext,
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let socketIdentifier = DNSServiceRefSockFD(service)
        assert(socketIdentifier >= 0)
        let socket = CFSocketCreateWithNative(
            /* allocator: */ nil,
            /* socket: */ socketIdentifier,
            /* callbackTypes: */ CFSocketCallBackType.ReadCallBack.rawValue,
            /* callout: */ querySocketCallback,
            /* context: */ &socketContext
        )
        // TODO: Is this socket retained here? If not, it crashes. If so, it leaks.
        queryContext.memory.socket = socket
        log.verbose("Created socket for query to domain `\(domain)`: \(socket)")

        // Add socket listener to run loop
        let runLoopSource = CFSocketCreateRunLoopSource(
            /* allocator: */ nil,
            /* socket: */ socket,
            /* order: */ 0
        )
        // TODO: Is this run loop retained here? If not, it crashes. If so, it leaks.
        queryContext.memory.runLoopSource = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, kCFRunLoopDefaultMode)
        log.verbose("Added run loop source \(runLoopSource) for query to domain `\(domain)`")
    }
}