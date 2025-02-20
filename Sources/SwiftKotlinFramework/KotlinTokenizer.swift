//
//  KotlinTokenizer.swift
//  SwiftKotlinFramework
//
//  Created by Angel Garcia on 14/09/16.
//  Copyright © 2016 Angel G. Olloqui. All rights reserved.
//

import Foundation
import Transform
import AST
import Source
import Parser

public class KotlinTokenizer: SwiftTokenizer {

    // MARK: - Declarations
    open override func tokenize(_ declaration: Declaration) -> [Token] {
        return super.tokenize(changeAccessLevelModifier(declaration))
    }

    open override func tokenize(_ constant: ConstantDeclaration) -> [Token] {
        // MOP-993: Replace assignment class
        let tokens = super.tokenize(constant)
            .replacing({ $0.value == "let"},
                       with: [constant.newToken(.keyword, "val")])
            .replacing({ $0.value == "DispatchSemaphore"},
                       with: [constant.newToken(.keyword, "Semaphore")])
        
        return tokens
    }
    
    open override func tokenize(_ declaration: FunctionDeclaration) -> [Token] {
        let attrsTokens = tokenize(declaration.attributes, node: declaration)
        let modifierTokens = declaration.modifiers.map { tokenize($0, node: declaration) }
            .joined(token: declaration.newToken(.space, " "))
        let genericParameterClauseTokens = declaration.genericParameterClause.map { tokenize($0, node: declaration) } ?? []
        
        let headTokens = [
            attrsTokens,
            modifierTokens,
            [declaration.newToken(.keyword, "fun")],
            genericParameterClauseTokens
        ].joined(token: declaration.newToken(.space, " "))
        
        var signatureTokens = tokenize(declaration.signature, node: declaration)
        var bodyTokens = declaration.body.map(tokenize) ?? []
        
        // MOP-424: Repair enums that being with "."
        var removeIndices = [Int]()
        for (index, token) in bodyTokens.enumerated() {
            if (token.value == ".") {
                if (index==0 || bodyTokens[index-1].kind == Token.Kind.startOfScope || bodyTokens[index-1].kind == Token.Kind.space || bodyTokens[index-1].kind == Token.Kind.delimiter || bodyTokens[index-1].value == " = "){
                    removeIndices.append(index)
                    
                    let capitalIndex = index+1 // MOP-468 Capitalize enum name
                    let oldToken = bodyTokens[capitalIndex]
                    bodyTokens.remove(at: capitalIndex)
                    bodyTokens.insert(declaration.newToken(oldToken.kind, oldToken.value.firstUppercased), at: capitalIndex)
                }
            }
        }
        let reversed : [Int] = removeIndices.reversed()
        for reversedIndex : Int in reversed {
            bodyTokens.remove(at: reversedIndex)
        }
        
        if declaration.isOverride {
            // overridden methods can't have default args in kotlin:
            signatureTokens = removeDefaultArgsFromParameters(tokens:signatureTokens)
        }
        var tokens = [
            headTokens,
            [declaration.newToken(.identifier, declaration.name)] + signatureTokens,
            bodyTokens
        ].joined(token: declaration.newToken(.space, " "))
        .prefix(with: declaration.newToken(.linebreak, "\n"))
        
        if (declaration.name.textDescription.hasPrefix("test")) {
            tokens = tokens.prefix(with: declaration.newToken(.comment, "@Test"))
        }
        
        return tokens
    }

    open override func tokenize(_ parameter: FunctionSignature.Parameter, node: ASTNode) -> [Token] {
        let nameTokens = [
            parameter.newToken(.identifier, parameter.localName, node)
        ]
        let typeAnnoTokens = tokenize(parameter.typeAnnotation, node: node)
        let defaultTokens = parameter.defaultArgumentClause.map {
            return parameter.newToken(.symbol, " = ", node) + tokenize($0)
        }
        let varargsTokens = parameter.isVarargs ? [
            parameter.newToken(.keyword, "vararg", node),
            parameter.newToken(.space, " ", node),
        ] : []

        return
            varargsTokens +
            nameTokens +
            typeAnnoTokens +
            defaultTokens
    }

    open override func tokenize(_ result: FunctionResult, node: ASTNode) -> [Token] {
        return super.tokenize(result, node: node)
            .replacing({ $0.value == "->"},
                       with: [result.newToken(.symbol, ":", node)])
    }
    
    open override func tokenize(_ member: ProtocolDeclaration.MethodMember, node: ASTNode) -> [Token] {
        return super.tokenize(member, node: node)
            .replacing({ $0.value == "func"},
                       with: [member.newToken(.keyword, "fun", node)])
    }

    open override func tokenize(_ declaration: ClassDeclaration) -> [Token] {
        let staticMembers = declaration.members.filter({ $0.isStatic })
        let newClass = ClassDeclaration(
            attributes: declaration.attributes,
            accessLevelModifier: declaration.accessLevelModifier,
            isFinal: false, // MOP-499 remove final class modifier
            name: declaration.name,
            genericParameterClause: declaration.genericParameterClause,
            typeInheritanceClause: declaration.typeInheritanceClause,
            genericWhereClause: declaration.genericWhereClause,
            members: declaration.members.filter({ !$0.isStatic }))
        declaration.lexicalParent.map(newClass.setLexicalParent)
        newClass.setSourceRange(declaration.sourceRange)
        var tokens = super.tokenize(newClass)
        
        var bodyStart = tokens.firstIndex(where: { $0.value == "{"})
                
        if let bodyIndex = bodyStart {
            // MOP-421
            let dataObjectIndex = tokens.firstIndex(where: { $0.value == "DataObject"})
            if (dataObjectIndex != nil && dataObjectIndex! < bodyIndex) {
                // MOP-422
                let constructorTokens = indent([declaration.newToken(.linebreak, "\n"),
                                                declaration.newToken(.space, "constructor(modelContext: ModelContext?, uid: String, source:DataObjectSource?) : super(modelContext, uid, source)"),
                                                declaration.newToken(.linebreak, "\n"),
                                                declaration.newToken(.space, "constructor(contextBearer: DataObject? = null) : super(contextBearer)"),
                                                declaration.newToken(.linebreak, "\n"),
                                                declaration.newToken(.linebreak, "\n"),
                                                declaration.newToken(.space, "override fun init(modelContext: ModelContext?, uid: String, source: DataObjectSource?): \(newClass.name) {"),
                                                declaration.newToken(.linebreak, "\n"),
                                                declaration.newToken(.space, "return \(newClass.name)(modelContext, uid, source)"),
                                                declaration.newToken(.linebreak, "\n"),
                                                declaration.newToken(.space, "}"),
                                                declaration.newToken(.linebreak, "\n")])
                
                tokens.insert(contentsOf: constructorTokens, at: bodyIndex + 1)
                bodyStart! += constructorTokens.count
            }
            
            // MOP-839: Properly translate BaseTest extension to constructor.
            let baseTestIndex = tokens.firstIndex(where: { $0.value == "BaseTest"})
            if (baseTestIndex != nil && baseTestIndex! < bodyIndex) {
                let baseTestToken = tokens[baseTestIndex!]
                tokens.remove(at: baseTestIndex!)
                tokens.insert(declaration.newToken(baseTestToken.kind, "BaseTest()"), at: baseTestIndex!)
                
                
                // MOP-839: Insert junit class annotations.
                let classindex = tokens.firstIndex(where: { $0.value == "class"})
                if (classindex != nil && classindex! < bodyIndex) {
                    let annotationTokens = indent([declaration.newToken(.space, "@RunWith(UnitTestRunner::class)"),
                                                    declaration.newToken(.linebreak, "\n"),
                                                    declaration.newToken(.space, "@Config(sdk = [24], application = UnitTestController::class)"),
                                                    declaration.newToken(.linebreak, "\n")])
                    
                    tokens.insert(contentsOf: annotationTokens, at: classindex!)
                    bodyStart! += annotationTokens.count
                }
            }
            
        }
        
        if !staticMembers.isEmpty, bodyStart != nil {
            let companionTokens = indent(tokenizeCompanion(staticMembers, node: declaration))
                .prefix(with: declaration.newToken(.linebreak, "\n"))
                .suffix(with: declaration.newToken(.linebreak, "\n"))
            tokens.insert(contentsOf: companionTokens, at: tokens.count - 1) // MOP-842
        }

        return tokens
    }

    open override func tokenize(_ declaration: StructDeclaration) -> [Token] {
        var staticMembers: [StructDeclaration.Member] = []
        var declarationMembers: [StructDeclaration.Member] = []
        var otherMembers: [StructDeclaration.Member] = []
        declaration.members.forEach { member in
            if member.isStatic {
                staticMembers.append(member)
            } else if member.declaration is ConstantDeclaration ||
                (member.declaration as? VariableDeclaration)?.initializerList != nil {
                declarationMembers.append(member)
            } else {
                otherMembers.append(member)
            }
        }

        let newStruct = StructDeclaration(
            attributes: declaration.attributes,
            accessLevelModifier: declaration.accessLevelModifier,
            name: declaration.name,
            genericParameterClause: declaration.genericParameterClause,
            typeInheritanceClause: nil,
            genericWhereClause: declaration.genericWhereClause,
            members: otherMembers)
        newStruct.setSourceRange(declaration.sourceRange)
        
        var tokens = super.tokenize(newStruct)
        if !declarationMembers.isEmpty || !otherMembers.isEmpty {
            tokens = tokens.replacing({ $0.value == "struct"},
                           with: [declaration.newToken(.keyword, "data class")])
        } else {
            tokens = tokens.replacing({ $0.value == "struct"},
                           with: [declaration.newToken(.keyword, "class")])
        }
            
        var codable = false
        if let typeInheritanceList = declaration.typeInheritanceClause?.typeInheritanceList.nonEquatable,
            typeInheritanceList.isEmpty == false,
            let bodyStart = tokens.firstIndex(where: { $0.value == "{"}) {
            let clause = TypeInheritanceClause(classRequirement: false, typeInheritanceList: typeInheritanceList)
            let inheritanceTokens = tokenize(clause, node: declaration)
            
            if inheritanceTokens.contains(where: {$0.value == "Codable" || $0.value == "Decodable"}) {
                codable = true
            }
        }
        
        if codable {
            tokens = tokens.prefix(with: declaration.newToken(.keyword, "@JsonClass(generateAdapter = true)"))
                .prefix(with: declaration.newToken(.linebreak, "\n"))
        }

        if !declarationMembers.isEmpty, let bodyStart = tokens.firstIndex(where: { $0.value == "{"}) {
            let linebreak = declaration.newToken(.linebreak, "\n")
            var declarationTokens: [Token]
            if declarationMembers.count == 1 {
                declarationTokens = declarationMembers
                        .flatMap { tokenize($0) }
            } else {
                let joinTokens = [
                    declaration.newToken(.delimiter, ",")
                ]
                declarationTokens = indent(
                    declarationMembers
                        .map { tokenize($0) }
                        .joined(tokens: joinTokens))
            }
            
            if codable { // MOP-1356 Codable/Decodable calsses to Moshi Json.
                var valIndex = -1
                var removeIndicesLog = [(Int, String)]()
                for (index, token) in declarationTokens.enumerated() {
                    if token.value == "val" {
                        valIndex = index
                    } else if valIndex != -1 && token.kind == .identifier {
                        
                        if token.value.contains(where: {$0.isUppercase}) {
                            var snakeCase = ""
                            for (_, c) in token.value.enumerated(){
                                if c.isUppercase {
                                    snakeCase += "_"
                                    snakeCase += c.lowercased()
                                }else {
                                    snakeCase.append(c)
                                }
                            }
                            
                         //   removeIndicesLog.append((valIndex, "@Json(name = \"\(snakeCase)\") val"))
                        }
                        
                        valIndex = -1
                    }
                }
                
                let reversedLog : [(Int, String)] = removeIndicesLog.reversed()
                for tuple in reversedLog {
                    declarationTokens.remove(at: tuple.0)
                    declarationTokens.insert(declaration.newToken(.keyword, tuple.1), at: tuple.0)
                }
            }
            
            tokens.insert(contentsOf: declarationTokens
                .prefix(with: declaration.newToken(.startOfScope, "("))
                .suffix(with: declaration.newToken(.endOfScope, ")")),
                          at: bodyStart - 1)
        }

        if let typeInheritanceList = declaration.typeInheritanceClause?.typeInheritanceList.nonEquatable,
            typeInheritanceList.isEmpty == false,
            let bodyStart = tokens.firstIndex(where: { $0.value == "{"}),
            codable == false{
            let clause = TypeInheritanceClause(classRequirement: false, typeInheritanceList: typeInheritanceList)
            let inheritanceTokens = tokenize(clause, node: declaration)
            
            tokens.insert(contentsOf: inheritanceTokens, at: bodyStart - 1)
        }

        if !staticMembers.isEmpty, let bodyStart = tokens.firstIndex(where: { $0.value == "{"}) {
            let companionTokens = indent(tokenizeCompanion(staticMembers, node: declaration))
                .prefix(with: declaration.newToken(.linebreak, "\n"))
                .suffix(with: declaration.newToken(.linebreak, "\n"))
                .replacing({ $0.value == "val"},
                           with: [declaration.newToken(.keyword, "const val")])
            tokens.insert(contentsOf: companionTokens, at: tokens.count - 1) // MOP-842
                            
        }

        return tokens
    }

    open override func tokenize(_ declaration: ProtocolDeclaration) -> [Token] {
        return super.tokenize(declaration)
            .replacing({ $0.value == "protocol"},
                       with: [declaration.newToken(.keyword, "interface")])
    }

    open override func tokenize(_ member: ProtocolDeclaration.PropertyMember, node: ASTNode) -> [Token] {
        let attrsTokens = tokenize(member.attributes, node: node)
        let modifiersTokens = tokenize(member.modifiers, node: node)

        return [
            attrsTokens,
            modifiersTokens,
            [member.newToken(.keyword, member.getterSetterKeywordBlock.setter == nil ? "val" : "var", node)],
            member.newToken(.identifier, member.name, node) + tokenize(member.typeAnnotation, node: node),
        ].joined(token: member.newToken(.space, " ", node))
    }

    open override func tokenize(_ modifier: AccessLevelModifier, node: ASTNode) -> [Token] {
        return [modifier.newToken(
            .keyword,
            modifier.rawValue.replacingOccurrences(of: "fileprivate", with: "private"),
            node)]
    }

    open override func tokenize(_ declaration: InitializerDeclaration) -> [Token] {
        var tokens = super.tokenize(declaration)

        // Find super.init and move to body start
        let superInitExpression = declaration.body.statements
            .compactMap { ($0 as? FunctionCallExpression)?.postfixExpression as? SuperclassExpression }
            .filter { $0.isInitializer }
            .first

        let selfInitExpression = declaration.body.statements
            .compactMap { ($0 as? FunctionCallExpression)?.postfixExpression as? SelfExpression }
            .filter { $0.isInitializer }
            .first

        let bodyStart = tokens.firstIndex(where: { $0.node === declaration.body })

        if  let bodyStart = bodyStart,
            let initExpression: ASTNode = superInitExpression ?? selfInitExpression,
            let superIndex = tokens.firstIndex(where: { $0.node === initExpression }),
            let endOfScopeIndex = tokens[superIndex...].firstIndex(where: { $0.kind == .endOfScope && $0.value == ")" }){
            let keyword = superInitExpression != nil ? "super" : "this"
            let superCallTokens = Array(tokens[superIndex...endOfScopeIndex])
                .replacing({ $0.node === initExpression }, with: [])
                .prefix(with: initExpression.newToken(.keyword, keyword))
                .prefix(with: initExpression.newToken(.space, " "))
                .prefix(with: initExpression.newToken(.symbol, ":"))
                .suffix(with: initExpression.newToken(.space, " "))

            tokens.removeSubrange((superIndex - 1)...(endOfScopeIndex + 1))
            tokens.insert(contentsOf: superCallTokens, at: bodyStart)
        }

        return tokens.replacing({ $0.value == "init"},
                                with: [declaration.newToken(.keyword, "constructor")])
    }

    open override func tokenize(_ modifier: DeclarationModifier, node: ASTNode) -> [Token] {
        switch modifier {
        case .static, .unowned, .unownedSafe, .unownedUnsafe, .weak, .convenience, .dynamic, .lazy, .class:
            return []
        case .accessLevel(let mod) where mod.rawValue.contains("(set)"):
            return []
        default:
            return super.tokenize(modifier, node: node)
        }
    }

    open override func tokenize(_ declaration: ExtensionDeclaration) -> [Token] {
        let inheritanceTokens = declaration.typeInheritanceClause.map {
            self.unsupportedTokens(message: "Kotlin does not support inheritance clauses in extensions:  \($0)", element: $0, node: declaration)
        } ?? []
        let whereTokens = declaration.genericWhereClause.map {
            self.unsupportedTokens(message: "Kotlin does not support where clauses in extensions:  \($0)", element: $0, node: declaration)
        } ?? []
        let typeTokens = tokenize(declaration.type, node: declaration)
        let accessLevelExtension = declaration.accessLevelModifier

        let memberTokens = declaration.members.map { member in
            var tokens = tokenize(member)
            let firstToken = tokens.firstIndex(where: { $0.kind != .linebreak }) ?? 0
            let accessLevelMemeber = tokens.compactMap { $0.origin as? AccessLevelModifier }.first
            if accessLevelMemeber == nil && accessLevelExtension != nil {
                let modifierTokens = tokenize(accessLevelExtension!, node: declaration).suffix(with: declaration.newToken(.space, " "))
                tokens.insert(contentsOf: modifierTokens, at: firstToken)
            }
            if let index = tokens.firstIndex(where: { $0.kind == .identifier }) {
                if member.isStatic {
                    tokens.insert(contentsOf: [declaration.newToken(.keyword, "Companion"), declaration.newToken(.delimiter, ".")], at: index)
                }
                tokens.insert(contentsOf: typeTokens + declaration.newToken(.delimiter, "."), at: index)
            }
            return tokens
        }.joined(token: declaration.newToken(.linebreak, "\n"))

        return [
            inheritanceTokens,
            whereTokens,
            memberTokens
        ].joined(token: declaration.newToken(.linebreak, "\n"))
    }
    
    open override func tokenize(_ declaration: VariableDeclaration) -> [Token] {
        let spaceToken = declaration.newToken(.space, " ")
        let attrsTokenGroups = declaration.attributes.map { tokenize($0, node: declaration) }
        var modifierTokenGroups = declaration.modifiers.map { tokenize($0, node: declaration) }
        var bodyTokens = tokenize(declaration.body, node: declaration)
        
        if declaration.isImplicitlyUnwrapped {
            modifierTokenGroups = [[declaration.newToken(.keyword, "lateinit")]] + modifierTokenGroups
        }
        
        if declaration.isOptional && declaration.initializerList?.last?.initializerExpression == nil {
                bodyTokens = bodyTokens + [
                    spaceToken,
                    declaration.newToken(.symbol, "="),
                    spaceToken,
                    declaration.newToken(.keyword, "null")
                ]
        } else if declaration.isLazy {
            bodyTokens = bodyTokens
                .replacing({ $0.value == " = " }, with: [
                    spaceToken,
                    declaration.newToken(.keyword, "by"),
                    spaceToken,
                    declaration.newToken(.keyword, "lazy"),
                    spaceToken,
                    ], amount: 1)
            if bodyTokens.last?.value == ")" {
                bodyTokens.removeLast()
            }
            if bodyTokens.last?.value == "(" {
                bodyTokens.removeLast()
            }
        }

        if declaration.isPrivateSet || declaration.isProtectedSet {
            let modifierToken = declaration.newToken(.keyword, declaration.isPrivateSet ? "private" : "protected")
            // If there is already a setter, change its accesibility
            if let setterIndex = bodyTokens.firstIndex(where: { $0.kind == .keyword && $0.value == "set" }) {
                bodyTokens.insert(contentsOf: [modifierToken, spaceToken], at: setterIndex)
            } else { // Else create modified setter
                bodyTokens.append(contentsOf:
                    [declaration.newToken(.linebreak, "\n")] +
                    indent([modifierToken, spaceToken, declaration.newToken(.keyword, "set")])
                )
            }
        }

        // MOP-424: Repair enums that being with "."
        var removeIndices = [Int]()
        for (index, token) in bodyTokens.enumerated() {
            if (token.value == ".") {
                if (index==0 || bodyTokens[index-1].kind == Token.Kind.startOfScope || bodyTokens[index-1].kind == Token.Kind.space || bodyTokens[index-1].kind == Token.Kind.delimiter){
                    removeIndices.append(index)
                    
                    let capitalIndex = index+1 // MOP-468 Capitalize enum name
                    let oldToken = bodyTokens[capitalIndex]
                    bodyTokens.remove(at: capitalIndex)
                    bodyTokens.insert(declaration.newToken(oldToken.kind, oldToken.value.firstUppercased), at: capitalIndex)
                }
            }
        }
        let reversed : [Int] = removeIndices.reversed()
        for reversedIndex : Int in reversed {
            bodyTokens.remove(at: reversedIndex)
        }
           
        // MOP-960 Convert Database query "clause" strings to StringBuilders.
        let isClause = bodyTokens.first?.value.lowercased().range(of:"clause") != nil && bodyTokens.last?.value.hasPrefix("\"") == true && bodyTokens.last?.value.hasSuffix("\"") == true
        
        if (isClause) {
            let stringBuilder = "StringBuilder(\(bodyTokens.last!.value))"
            bodyTokens.removeLast()
            bodyTokens.append(declaration.newToken(.keyword, stringBuilder))
        }
        
        let mutabilityTokens = [declaration.newToken(.keyword, declaration.isReadOnly || isClause || bodyTokens.contains(where: { $0.value == "mutableListOf" || $0.value == "mutableMapOf" }) ? "val" : "var")] // MOP-843 Mutable maps and lists to val
        
        return [
            attrsTokenGroups.joined(token: spaceToken),
            modifierTokenGroups.joined(token: spaceToken),
            mutabilityTokens,
            bodyTokens
        ].joined(token: spaceToken)
    }

    open override func tokenize(_ body: VariableDeclaration.Body, node: ASTNode) -> [Token] {
        switch body {
        case let .codeBlock(name, typeAnnotation, codeBlock):
            let getterTokens = [
                body.newToken(.keyword, "get()", node),
                body.newToken(.space, " ", node)
            ]
            return body.newToken(.identifier, name, node) +
                tokenize(typeAnnotation, node: node) +
                body.newToken(.linebreak, "\n", node) +
                indent(
                    getterTokens +
                    tokenize(codeBlock)
                ) + body.newToken(.linebreak, "\n", node) //MOP-468: variable declaration newline
            
            
        case let .willSetDidSetBlock(name, typeAnnotation, initExpr, block):
            let newName = block.willSetClause?.name ?? .name("newValue")
            let oldName = block.didSetClause?.name ?? .name("oldValue")
            let fieldAssignmentExpression = AssignmentOperatorExpression(
                leftExpression: IdentifierExpression(kind: IdentifierExpression.Kind.identifier(.name("field"), nil)),
                rightExpression: IdentifierExpression(kind: IdentifierExpression.Kind.identifier(newName, nil))
            )
            let oldValueAssignmentExpression = ConstantDeclaration(initializerList: [
                PatternInitializer(pattern: IdentifierPattern(identifier: oldName),
                                   initializerExpression: IdentifierExpression(kind: IdentifierExpression.Kind.identifier(.name("field"), nil)))
            ])
            let setterCodeBlock = CodeBlock(statements:
                    (block.didSetClause?.codeBlock.statements.count ?? 0 > 0 ? [oldValueAssignmentExpression] : []) +
                    (block.willSetClause?.codeBlock.statements ?? []) +
                    [fieldAssignmentExpression] +
                    (block.didSetClause?.codeBlock.statements ?? [])
            )
            let setterTokens = tokenize(GetterSetterBlock.SetterClause(name: newName, codeBlock: setterCodeBlock), node: node)            
            let typeAnnoTokens = typeAnnotation.map { tokenize($0, node: node) } ?? []
            let initTokens = initExpr.map { body.newToken(.symbol, " = ", node) + tokenize($0) } ?? []
            return [
                body.newToken(.identifier, name, node)] +
                typeAnnoTokens +
                initTokens +
                [body.newToken(.linebreak, "\n", node)] +
                indent(setterTokens)
            
        default:
            return super.tokenize(body, node: node).removingTrailingSpaces()
        }
    }

    open override func tokenize(_ block: GetterSetterBlock, node: ASTNode) -> [Token] {
        block.getter.codeBlock.setLexicalParent(node)
        let getterTokens = tokenize(block.getter, node: node)
            .replacing({ $0.kind == .keyword && $0.value == "get" }, with: [block.newToken(.keyword, "get()", node)])
        let setterTokens = block.setter.map { tokenize($0, node: node) } ?? []
                
        return [
            indent(getterTokens),
            indent(setterTokens),
        ].joined(token: block.newToken(.linebreak, "\n", node))
        .prefix(with: block.newToken(.linebreak, "\n", node))
    }

    open override func tokenize(_ block: GetterSetterBlock.SetterClause, node: ASTNode) -> [Token] {
        let newSetter = GetterSetterBlock.SetterClause(attributes: block.attributes,
                                                       mutationModifier: block.mutationModifier,
                                                       name: block.name ?? .name("newValue"),
                                                       codeBlock: block.codeBlock)        
        return super.tokenize(newSetter, node: node)
    }

    open override func tokenize(_ block: WillSetDidSetBlock, node: ASTNode) -> [Token] {
        let name = block.willSetClause?.name ?? block.didSetClause?.name ?? .name("newValue")
        let willSetBlock = block.willSetClause.map { tokenize($0.codeBlock) }?.tokensOnScope(depth: 1) ?? []
        let didSetBlock = block.didSetClause.map { tokenize($0.codeBlock) }?.tokensOnScope(depth: 1) ?? []
        let assignmentBlock = [
            block.newToken(.identifier, "field", node),
            block.newToken(.keyword, " = ", node),
            block.newToken(.identifier, name, node)
        ]
        return [
            [block.newToken(.startOfScope, "{", node)],
            willSetBlock,
            indent(assignmentBlock),
            didSetBlock,
            [block.newToken(.endOfScope, "}", node)]
        ].joined(token: block.newToken(.linebreak, "\n", node))
        
    }
    
    open override func tokenize(_ declaration: ImportDeclaration) -> [Token] {
        return []
    }
    
    open override func tokenize(_ declaration: EnumDeclaration) -> [Token] {
        let unionCases = declaration.members.compactMap { $0.unionStyleEnumCase }
        let simpleCases = unionCases.flatMap { $0.cases }
        let lineBreak = declaration.newToken(.linebreak, "\n")

        guard unionCases.count <= declaration.members.count && // unionCases is 0 when enums have specific values
            declaration.genericParameterClause == nil &&
            declaration.genericWhereClause == nil else {
                return self.unsupportedTokens(message: "Complex enums not supported yet", element: declaration, node: declaration).suffix(with: lineBreak) +
                    super.tokenize(declaration)
        }

        // Simple enums (no tuple values)
        if !simpleCases.contains(where: { $0.tuple != nil }) {
            
            var finalTokens: [Token] = [] // MOP-1154: Proper enum naming.
            
            let typeInheritanceList = declaration.typeInheritanceClause?.typeInheritanceList.nonEquatable
            if typeInheritanceList?.isEmpty == false {
                let tokens = tokenizeSimpleValueEnum(declaration: declaration, simpleCases: simpleCases)
                
                for (index, token) in tokens.enumerated() {
                    let valid = index > 0 && index < (tokens.count - 1)
                    if (token.kind == .delimiter && token.value == ",") {
                        finalTokens.append(token)
                        finalTokens.append(declaration.newToken(.linebreak, "\n "))
                    } else if (token.kind == .identifier) {
                        if (valid && tokens[index+1].value == "(" &&
                            (tokens[index-1].kind == .space || tokens[index-1].kind == .linebreak ||
                             tokens[index-1].kind == .indentation)) {
                            finalTokens.append(declaration.newToken(.identifier, token.value.firstUppercased))
                        } else {
                            finalTokens.append(token)
                        }
                    }
                    else {
                        finalTokens.append(token)
                    }
                }
                
            } else {
                let tokens = tokenizeNoValueEnum(declaration: declaration, simpleCases: simpleCases)
                
                for (index, token) in tokens.enumerated() {
                    let valid = index > 0 && index < (tokens.count - 1)
                    if (token.kind == .delimiter && token.value == ",") {
                        finalTokens.append(token)
                        finalTokens.append(declaration.newToken(.linebreak, "\n "))
                    } else if (token.kind == .identifier) {
                        if (valid && tokens[index+1].value == "(" &&
                            (tokens[index-1].kind == .space || tokens[index-1].kind == .linebreak ||
                             tokens[index-1].kind == .indentation)) {
                            finalTokens.append(declaration.newToken(.identifier, token.value.firstUppercased))
                        } else {
                            finalTokens.append(token)
                        }
                    }
                    else {
                        finalTokens.append(token)
                    }
                }
            }
            
            if let caseIterableIndex = finalTokens.firstIndex(where: {$0.value == "CaseIterable"}) {
                finalTokens.remove(at: caseIterableIndex)
                finalTokens.remove(at: caseIterableIndex - 1)
                finalTokens.remove(at: caseIterableIndex - 2)
            }
            
            return finalTokens
        }
        // Tuples or inhertance required sealed classes
        else {
            return tokenizeSealedClassEnum(declaration: declaration, simpleCases: simpleCases)
        }
    }
    
    open override func tokenize(_ codeBlock: CodeBlock) -> [Token] {
        guard codeBlock.statements.count == 1, let statement = codeBlock.statements.first, let parent = codeBlock.lexicalParent,
            !(statement is SwitchStatement), !(statement is IfStatement),    // Conditional statements have returns inside that are not compatible with the = optimization
            parent is VariableDeclaration || (parent as? FunctionDeclaration)?.signature.result != nil
            else { return super.tokenize(codeBlock) }

        let bodyTokens: [Token]
        if let returnStatement = statement as? ReturnStatement {
            bodyTokens = returnStatement.expression.map { tokenize($0) } ?? []
        } else {
            bodyTokens = tokenize(statement)
        }
        let sameLine = parent is VariableDeclaration
        let separator = sameLine ? codeBlock.newToken(.space, " ") : codeBlock.newToken(.linebreak, "\n")
        return [
            [codeBlock.newToken(.symbol, "=")],
            sameLine ? bodyTokens : indent(bodyTokens)
        ].joined(token: separator)
    }
    
    // MARK: - Statements

    open override func tokenize(_ statement: GuardStatement) -> [Token] {
        let declarationTokens = tokenizeDeclarationConditions(statement.conditionList, node: statement)
        if statement.isUnwrappingGuard, let body = statement.codeBlock.statements.first {
            let tokens = [
                Array(declarationTokens.dropLast()),
                [statement.newToken(.symbol, "?:")],
                tokenize(body)
            ].joined(token: statement.newToken(.space, " "))
            return tokens + [statement.newToken(.linebreak, "\n")] // MOP-499 newline
        } else {
            let invertedConditions = statement.conditionList.map(InvertedCondition.init)
            return declarationTokens + [
                [statement.newToken(.keyword, "if")],
                tokenize(invertedConditions, node: statement),
                tokenize(statement.codeBlock)
            ].joined(token: statement.newToken(.space, " "))
        }
    }

    open override func tokenize(_ statement: IfStatement) -> [Token] {
        return tokenizeDeclarationConditions(statement.conditionList, node: statement) +
            super.tokenize(statement) +
            [statement.newToken(.linebreak, "\n")] // MOP-499 newline
    }

    open override func tokenize(_ statement: SwitchStatement) -> [Token] {
        var casesTokens = statement.newToken(.startOfScope, "{") + statement.newToken(.endOfScope, "}")
        if !statement.cases.isEmpty {
            casesTokens = [
                [statement.newToken(.startOfScope, "{")],
                indent(
                    statement.cases.map { tokenize($0, node: statement) }
                    .joined(token: statement.newToken(.linebreak, "\n"))),
                [statement.newToken(.endOfScope, "}")]
                ].joined(token: statement.newToken(.linebreak, "\n"))
        }

        return [
            [statement.newToken(.keyword, "when")],
            tokenize(statement.expression)
                .prefix(with: statement.newToken(.startOfScope, "("))
                .suffix(with: statement.newToken(.endOfScope, ")")),
            casesTokens,
            [statement.newToken(.linebreak, "\n")]
            ].joined(token: statement.newToken(.space, " "))
    }

    open override func tokenize(_ statement: SwitchStatement.Case, node: ASTNode) -> [Token] {
        let separatorTokens =  [
            statement.newToken(.space, " ", node),
            statement.newToken(.delimiter, "->", node),
            statement.newToken(.space, " ", node),
        ]
        switch statement {
        case let .case(itemList, stmts):
            let conditions = itemList.map { tokenize($0, node: node) }.joined(token: statement.newToken(.delimiter, ", ", node))
            var statements = tokenize(stmts, node: node)
            if stmts.count > 1 || statements.filter({ $0.kind == .linebreak }).count > 1 {
                let linebreak = statement.newToken(.linebreak, "\n", node)
                statements = [statement.newToken(.startOfScope, "{", node), linebreak] +
                    indent(statements) +
                    [linebreak, statement.newToken(.endOfScope, "}", node)]
            }
            
            return conditions + separatorTokens + statements

        case .default(let stmts):
            return
                [statement.newToken(.keyword, "else", node)] +
                    separatorTokens +
                    tokenize(stmts, node: node)
        }
    }

    open override func tokenize(_ statement: SwitchStatement.Case.Item, node: ASTNode) -> [Token] {
        let prefix: [Token]
        if let expression = (statement.pattern as? ExpressionPattern)?.expression {
            prefix = !(expression is LiteralExpression) ? [statement.newToken(.keyword, "in", node)] : []
        } else {
            prefix = []
        }
        return [
            prefix,
            super.tokenize(statement, node: node)
        ].joined(token: statement.newToken(.space, " ", node))
    }

    open override func tokenize(_ pattern: EnumCasePattern, node: ASTNode) -> [Token] {
        let patternWithoutTuple: EnumCasePattern
        let prefix: [Token]
        if pattern.tuplePattern != nil {
            patternWithoutTuple = EnumCasePattern(typeIdentifier: pattern.typeIdentifier, name: pattern.name, tuplePattern: nil)
            prefix = [pattern.newToken(.keyword, "is", node), pattern.newToken(.space, " ", node)]
        } else {
            patternWithoutTuple = pattern
            prefix = []
        }
        var tokens = super.tokenize(patternWithoutTuple, node: node)
        if tokens.first?.value == "." {
            tokens.remove(at: 0)
            // MOP-468: Uppercase the first letter of enum.
            let oldToken = tokens.first
            if(oldToken != nil){
                tokens.remove(at: 0)
                tokens.insert(pattern.newToken(oldToken!.kind, oldToken!.value.firstUppercased, node), at: 0) 
            }
        }
        
        return prefix + tokens
    }

    open override func tokenize(_ statement: ForInStatement) -> [Token] {
        var tokens = super.tokenize(statement)
        if let endIndex = tokens.firstIndex(where: { $0.value == "{"}) {
            tokens.insert(statement.newToken(.endOfScope, ")"), at: endIndex - 1)
            tokens.insert(statement.newToken(.startOfScope, "("), at: 2)
        }
        return tokens
    }

    // MARK: - Expressions
    open override func tokenize(_ expression: ExplicitMemberExpression) -> [Token] {
        switch expression.kind {
        case let .namedType(postfixExpr, identifier):
            
            var checkedIdentifier = identifier.textDescription
            if (checkedIdentifier == "isNilOrEmpty") {
                checkedIdentifier = "isNullOrEmpty()"
            } else if (checkedIdentifier == "sharedInstance") {
                checkedIdentifier = "instance"
            }
            
            let postfixTokens = tokenize(postfixExpr)
            var delimiters = [expression.newToken(.delimiter, ".")]

            if postfixTokens.last?.value != "?" &&
                postfixTokens.removingOtherScopes().contains(where: {
                    $0.value == "?" && $0.origin is OptionalChainingExpression
                }) {
                delimiters = delimiters.prefix(with: expression.newToken(.symbol, "?"))
            }
            return postfixTokens + delimiters + expression.newToken(.identifier, checkedIdentifier)
        default:
            return super.tokenize(expression)
        }
    }

    open override func tokenize(_ expression: AssignmentOperatorExpression) -> [Token] {
        guard expression.leftExpression is WildcardExpression else {
            return super.tokenize(expression)
        }
        return tokenize(expression.rightExpression)
    }

    open override func tokenize(_ expression: LiteralExpression) -> [Token] {
        switch expression.kind {
        case .nil:
            return [expression.newToken(.keyword, "null")]
        case let .interpolatedString(_, rawText):
            return tokenizeInterpolatedString(rawText, node: expression)
        case let .staticString(_, rawText):
            return [expression.newToken(.string, conversionUnicodeString(rawText, node: expression))]
        case .array(let exprs):
            let isGenericTypeInfo = (expression.lexicalParent as? FunctionCallExpression)?.postfixExpression.textDescription.starts(with: "[") == true
            return expression.newToken(.identifier, "mutableListOf") + // MOP-468: listOf to mutableListOf
                expression.newToken(.startOfScope, isGenericTypeInfo ? "<" : "(") +
                exprs.map { tokenize($0) }.joined(token: expression.newToken(.delimiter, ", ")) +
                expression.newToken(.endOfScope, isGenericTypeInfo ? ">" : ")")
        case .dictionary(let entries):
            let isGenericTypeInfo = expression.lexicalParent is FunctionCallExpression
            var entryTokens = entries.map { tokenize($0, node: expression) }.joined(token: expression.newToken(.delimiter, ", "))
            if isGenericTypeInfo {
                entryTokens = entryTokens.replacing({ $0.value == "to"}, with: [expression.newToken(.delimiter, ",") ])
            }
            return [expression.newToken(.identifier, "mutableMapOf"),
                expression.newToken(.startOfScope, isGenericTypeInfo ? "<" : "(")] +
                entryTokens +
                [expression.newToken(.endOfScope, isGenericTypeInfo ? ">" : ")")]
        default:
            return super.tokenize(expression)
        }
    }

    open override func tokenize(_ entry: DictionaryEntry, node: ASTNode) -> [Token] {
        return tokenize(entry.key) +
            entry.newToken(.space, " ", node) +
            entry.newToken(.keyword, "to", node) +
            entry.newToken(.space, " ", node) +
            tokenize(entry.value)
    }

    open override func tokenize(_ expression: SelfExpression) -> [Token] {
        return super.tokenize(expression)
            .replacing({ $0.value == "self"},
                       with: [expression.newToken(.keyword, "this")])
    }

    open override func tokenize(_ expression: IdentifierExpression) -> [Token] {
        switch expression.kind {
        case let .implicitParameterName(i, generic) where i == 0:
            return expression.newToken(.identifier, "it") +
                generic.map { tokenize($0, node: expression) }
        default:
            return super.tokenize(expression)
        }
    }
    
    open override func tokenize(_ expression: ImplicitMemberExpression) -> [Token] {
        return [expression.newToken(.identifier, expression.identifier.description.firstUppercased)]
    }

    open override func tokenize(_ expression: BinaryOperatorExpression) -> [Token] {
        let binaryOperator: Operator
        switch expression.binaryOperator {
        case "..<": binaryOperator = "until"
        case "...": binaryOperator = ".."
        case "??": binaryOperator = "?:"
        default: binaryOperator = expression.binaryOperator
        }
        return super.tokenize(expression)
            .replacing({ $0.kind == .symbol && $0.value == expression.binaryOperator },
                       with: [expression.newToken(.symbol, binaryOperator)])
    }

    open override func tokenize(_ expression: FunctionCallExpression) -> [Token] {
        var tokens = super.tokenize(expression)
        if (expression.postfixExpression is OptionalChainingExpression || expression.postfixExpression is ForcedValueExpression),
            let startIndex = tokens.indexOf(kind: .startOfScope, after: 0) {
            tokens.insert(contentsOf: [
                expression.newToken(.symbol, "."),
                expression.newToken(.keyword, "invoke")
            ], at: startIndex)
        }
        
        // MOP-468: Remove "helper" function calls
        var removeIndices = [Int]()
        for (index, token) in tokens.enumerated() {
            if (token.value == "helper"){
                removeIndices.append(index-1)
                removeIndices.append(index)
            }
        }
        let reversed : [Int] = removeIndices.reversed()
        for reversedIndex : Int in reversed {
            if reversedIndex >= 0 {
                tokens.remove(at: reversedIndex)
            }
        }
        
        // MOP-468: "Log" to "Logger" Replace function names
        var removeIndicesLog = [(Int, String)]()
        for (index, token) in tokens.enumerated() {
            if (token.value == "Log"){
                removeIndicesLog.append((index, "Logger"))
            } else if (token.value == "lowercased") {
                removeIndicesLog.append((index, "lowercase"))
            } else if (token.value == "uppercased") {
                   removeIndicesLog.append((index, "uppercase"))
            } else if (token.value == "forceEmptyToNil") {
                removeIndicesLog.append((index, "forceEmptyToNull"))
            } else if (token.value == "hasPrefix") {
                removeIndicesLog.append((index, "startsWith"))
            } else if (token.value == "hasSuffix") {
                removeIndicesLog.append((index, "endsWith"))
            } else if (token.value == "emptyStringAsNilEquivalent") {
                removeIndicesLog.append((index, "emptyStringAsNullEquivalent"))
            } else if (token.value == "isNilOrEmpty") {
                removeIndicesLog.append((index, "isNullOrEmpty()"))
            } else if (token.value == "sharedInstance") {
                removeIndicesLog.append((index, "instance"))
            } else if (token.value == "compare") {
                removeIndicesLog.append((index, "compareTo"))
            } else if (token.value == "compactMap") {
                removeIndicesLog.append((index, "mapNotNull"))
            } else if (token.value == "wait") {
                removeIndicesLog.append((index, "acquire"))
            } else if (token.value == "removeValue") {
                removeIndicesLog.append((index, "remove"))
            } else if (token.value == "replacingOccurrences") {
                removeIndicesLog.append((index, "replace"))
            } else if (token.value == "signal") {
                removeIndicesLog.append((index, "release"))
            } else if (token.value == "XCTAssert") {
                removeIndicesLog.append((index, "assertTrue"))
            } else if (token.value == "XCTAssertTrue") {
                removeIndicesLog.append((index, "assertTrue"))
            } else if (token.value == "XCTAssertFalse") {
                removeIndicesLog.append((index, "assertFalse"))
            } else if (token.value == "XCTAssertEqual") {
                removeIndicesLog.append((index, "assertEquals"))
            } else if (token.value == "XCTFail") {
                removeIndicesLog.append((index, "fail"))
            } else if (token.value == "XCTAssertGreaterThan") {
                removeIndicesLog.append((index, "assertGreaterThan"))
            } else if (token.value == "XCTAssertNil") {
                removeIndicesLog.append((index, "assertNull"))
            } else if (token.value == "XCTAssertNotNil") {
                removeIndicesLog.append((index, "assertNotNull"))
            } else if (token.value == "XCTAssertLessThan") {
                removeIndicesLog.append((index, "assertLessThan"))
            } else if (token.value == "XCTAssertLessThanOrEqual") {
                removeIndicesLog.append((index, "assertLessThanOrEqual"))
            } else if (token.value == "XCTAssertGreaterThanOrEqual") {
                removeIndicesLog.append((index, "assertGreaterThanOrEqual"))
            }
            
        }
        let reversedLog : [(Int, String)] = removeIndicesLog.reversed()
        for tuple in reversedLog {
            tokens.remove(at: tuple.0)
            tokens.insert(expression.newToken(.identifier, tuple.1), at: tuple.0)
        }
        
        // MOP-836: Remove blockingWaitForExpectations arguments.
        let nameIndex = tokens.firstIndex(where: {$0.value == "blockingWaitForExpectations"})
        if (nameIndex != nil) {
            let startIndex = (tokens.firstIndex(where: {$0.kind == .startOfScope}) ?? 999) + 1
            let endIndex = (tokens.firstIndex(where: {$0.kind == .endOfScope}) ?? -999) - 1
            if (startIndex <= endIndex) {
                tokens.removeSubrange(startIndex...endIndex)
            }
        }
        
        // MOP-1032: add typing to objectstArray function calls.
        if tokens.contains(where: {$0.value == "objectsArray"}) {
            var type : String? = nil
            for (index, token) in tokens.enumerated() {
                if (type == nil && token.kind == .identifier && !token.value.isEmpty &&    token.value[token.value.startIndex].isUppercase) {
                    type = token.value
                    continue
                }
                if let type = type, token.value == "objectsArray" {
                    tokens.insert(expression.newToken(.keyword, "<\(type)>"), at: index + 1)
                    break
                }
            }
        }
        
        return tokens
    }
    
    open override func tokenize(_ expression: FunctionCallExpression.Argument, node: ASTNode) -> [Token] {
        var tokenizedArgument = super.tokenize(expression, node: node)
            .replacing({ $0.value == ": " && $0.kind == .delimiter },
                       with: [expression.newToken(.delimiter, " = ", node)])
                
        // MOP-427, MOP-2010: Remove specific argument names
        var removeIndices = [Int]()
        for (index, token) in tokenizedArgument.enumerated() {
            if (token.value == " = " && token.kind == .delimiter &&
                (tokenizedArgument[index - 1].value.starts(with: "for") ||
                 tokenizedArgument[index - 1].value.starts(with: "by") ||
                 tokenizedArgument[index - 1].value.starts(with: "with") ||
                 tokenizedArgument[index - 1].value == "value" ||
                 tokenizedArgument[index - 1].value == "params" ||
                 tokenizedArgument[index - 1].value == "object")){
                removeIndices.append(index-1)
                removeIndices.append(index)
            }
        }
        let reversed : [Int] = removeIndices.reversed()
        for reversedIndex : Int in reversed {
            tokenizedArgument.remove(at: reversedIndex)
        }
        
        // MOP-468: Fix enum argument, uppercase first letter of enum
        let first = tokenizedArgument.first
        if (first?.value == "."){
            tokenizedArgument.remove(at: 0)
            let oldToken = tokenizedArgument.first
            if(oldToken != nil){
                tokenizedArgument.remove(at: 0)
                tokenizedArgument.insert(expression.newToken(oldToken!.kind, oldToken!.value.firstUppercased, node), at: 0)
            }
        }
        
        return tokenizedArgument
    }

    open override func tokenize(_ expression: ClosureExpression) -> [Token] {
        var tokens = super.tokenize(expression)
        if expression.signature != nil {
            let arrowTokens = expression.signature?.parameterClause != nil ? [expression.newToken(.symbol, " -> ")] : []
            tokens = tokens.replacing({ $0.value == "in" },
                                      with: arrowTokens,
                                      amount: 1)
        }
        
        // Last return can be removed
        if let lastReturn = expression.statements?.last as? ReturnStatement,
            let index = tokens.firstIndex(where: { $0.node === lastReturn && $0.value == "return" }) {
            tokens.remove(at: index)
            tokens.remove(at: index)
        }
        
        // Other returns must be suffixed with call name
        if let callExpression = expression.lexicalParent as? FunctionCallExpression,
            let memberExpression = callExpression.postfixExpression as? ExplicitMemberExpression {
            while let returnIndex = tokens.firstIndex(where: { $0.value == "return" }) {
                tokens.remove(at: returnIndex)
                tokens.insert(expression.newToken(.keyword, "return@"), at: returnIndex)
                tokens.insert(expression.newToken(.identifier, memberExpression.identifier), at: returnIndex + 1)
            }
        }
        return tokens
    }

    open override func tokenize(_ expression: ClosureExpression.Signature, node: ASTNode) -> [Token] {
        return expression.parameterClause.map { tokenize($0, node: node) } ?? []
    }

    open override func tokenize(_ expression: ClosureExpression.Signature.ParameterClause, node: ASTNode) -> [Token] {
        switch expression {
        case .parameterList(let params):
            return params.map { tokenize($0, node: node) }.joined(token: expression.newToken(.delimiter, ", ", node))
        default:
            return super.tokenize(expression, node: node)
        }
    }

    open override func tokenize(_ expression: ClosureExpression.Signature.ParameterClause.Parameter, node: ASTNode) -> [Token] {
        return [expression.newToken(.identifier, expression.name, node)]
    }

    open override func tokenize(_ expression: TryOperatorExpression) -> [Token] {
        switch expression.kind {
        case .try(let expr):
            return tokenize(expr)
        case .forced(let expr):
            return tokenize(expr)
        case .optional(let expr):
            let catchSignature = [
                expression.newToken(.startOfScope, "("),
                expression.newToken(.identifier, "e"),
                expression.newToken(.delimiter, ":"),
                expression.newToken(.space, " "),
                expression.newToken(.identifier, "Throwable"),
                expression.newToken(.endOfScope, ")"),
            ]
            let catchBodyTokens = [
                expression.newToken(.startOfScope, "{"),
                expression.newToken(.space, " "),
                expression.newToken(.keyword, "null"),
                expression.newToken(.space, " "),
                expression.newToken(.endOfScope, "}"),
            ]
            return [
                [expression.newToken(.keyword, "try")],
                [expression.newToken(.startOfScope, "{")],
                tokenize(expr),
                [expression.newToken(.endOfScope, "}")],
                [expression.newToken(.keyword, "catch")],
                catchSignature,
                catchBodyTokens
            ].joined(token: expression.newToken(.space, " "))
        }
    }

    open override func tokenize(_ expression: ForcedValueExpression) -> [Token] {
        return tokenize(expression.postfixExpression) + expression.newToken(.symbol, "!!")
    }

    open override func tokenize(_ expression: TernaryConditionalOperatorExpression) -> [Token] {
        return [
            [expression.newToken(.keyword, "if")],
            tokenize(expression.conditionExpression)
                .prefix(with: expression.newToken(.startOfScope, "("))
                .suffix(with: expression.newToken(.endOfScope, ")")),
            tokenize(expression.trueExpression),
            [expression.newToken(.keyword, "else")],
            tokenize(expression.falseExpression),
            ].joined(token: expression.newToken(.space, " "))
    }


    open override func tokenize(_ expression: SequenceExpression) -> [Token] {
        var elementTokens = expression.elements.map({ tokenize($0, node: expression) })

        //If there is a ternary, then prefix with if
        if let ternaryOperatorIndex = expression.elements.firstIndex(where: { $0.isTernaryConditionalOperator }),
            ternaryOperatorIndex > 0 {
            let assignmentIndex = expression.elements.firstIndex(where: { $0.isAssignmentOperator }) ?? -1
            let prefixTokens = [
                expression.newToken(.keyword, "if"),
                expression.newToken(.space, " "),
                expression.newToken(.startOfScope, "("),
            ]
            elementTokens[assignmentIndex + 1] =
                prefixTokens +
                elementTokens[assignmentIndex + 1]
            elementTokens[ternaryOperatorIndex - 1] = elementTokens[ternaryOperatorIndex - 1]
                .suffix(with: expression.newToken(.endOfScope, ")"))
        }
        return elementTokens.joined(token: expression.newToken(.space, " "))
    }

    open override func tokenize(_ element: SequenceExpression.Element, node: ASTNode) -> [Token] {
        switch element {
        case .ternaryConditionalOperator(let expr):
            return [
                tokenize(expr),
                [node.newToken(.keyword, "else")],
                ].joined(token: node.newToken(.space, " "))
        default:
            return super.tokenize(element, node: node)
        }
    }

    open override func tokenize(_ expression: OptionalChainingExpression) -> [Token] {
        var tokens = tokenize(expression.postfixExpression)
        if tokens.last?.value != "this" {
            tokens.append(expression.newToken(.symbol, "?"))
        }
        return tokens
    }

    open override func tokenize(_ expression: TypeCastingOperatorExpression) -> [Token] {
        switch expression.kind {
        case let .forcedCast(expr, type):
            return [
                tokenize(expr),
                [expression.newToken(.keyword, "as")],
                tokenize(type, node: expression)
            ].joined(token: expression.newToken(.space, " "))
        default:
            return super.tokenize(expression)
        }
    }

    
    // MARK: - Types
    open override func tokenize(_ type: ArrayType, node: ASTNode) -> [Token] {
        return
            type.newToken(.identifier, "List", node) +
            type.newToken(.startOfScope, "<", node) +
            tokenize(type.elementType, node: node) +
            type.newToken(.endOfScope, ">", node)
    }

    open override func tokenize(_ type: DictionaryType, node: ASTNode) -> [Token] {
        let keyTokens = tokenize(type.keyType, node: node)
        let valueTokens = tokenize(type.valueType, node: node)
        return
            [type.newToken(.identifier, "Map", node), type.newToken(.startOfScope, "<", node)] +
            keyTokens +
            [type.newToken(.delimiter, ", ", node)] +
            valueTokens +
            [type.newToken(.endOfScope, ">", node)]
    }

    open override func tokenize(_ type: FunctionType, node: ASTNode) -> [Token] {
        return super.tokenize(type, node: node)
            .replacing({ $0.value == "Void" && $0.kind == .identifier },
                       with: [type.newToken(.identifier, "Unit", node)])
    }

    open override func tokenize(_ type: TypeIdentifier.TypeName, node: ASTNode) -> [Token] {
        let typeMap = [
            "Bool": "Boolean",
            "AnyObject": "Any"
        ]
        return type.newToken(.identifier, typeMap[type.name.textDescription] ?? type.name.textDescription, node) +
            type.genericArgumentClause.map { tokenize($0, node: node) }
    }

    open override func tokenize(_ type: ImplicitlyUnwrappedOptionalType, node: ASTNode) -> [Token] {
        return tokenize(type.wrappedType, node: node)
    }

    open override func tokenize(_ attribute: Attribute, node: ASTNode) -> [Token] {
        if ["escaping", "autoclosure", "discardableResult"].contains(attribute.name.textDescription) {
            return []
        }
        return super.tokenize(attribute, node: node)
    }

    open override func tokenize(_ type: TupleType, node: ASTNode) -> [Token] {
        var typeWithNames = [TupleType.Element]()

        for (index, element) in type.elements.enumerated() {
            if element.name != nil || element.type is FunctionType {
                typeWithNames.append(element)
            } else {
                typeWithNames.append(TupleType.Element(type: element.type, name: .name("v\(index + 1)"), attributes: element.attributes, isInOutParameter: element.isInOutParameter))
            }
        }
        
        if typeWithNames.count == 2 { // MOP-1453: Pair type
            var tokens : [Token] = []
            tokens.append(type.newToken(.identifier, "Pair", node))
            tokens.append(type.newToken(.startOfScope, "<", node))
            let first = tokenize(typeWithNames.first!, node: node)
            var firstTokens : [Token] = []
            for token in first {
                firstTokens.append(token)
                if token.kind == .delimiter {
                    firstTokens.removeAll()
                }
            }
            tokens += firstTokens
            tokens.append(type.newToken(.space, ", ", node))
            let second = tokenize(typeWithNames.last!, node: node)
            var secondTokens : [Token] = []
            for token in second {
                secondTokens.append(token)
                if token.kind == .delimiter {
                    secondTokens.removeAll()
                }
            }
            tokens += secondTokens
            tokens.append(type.newToken(.endOfScope, ">", node))

            return tokens
        }
        
        
        return type.newToken(.startOfScope, "(", node) +
            typeWithNames.map { tokenize($0, node: node) }.joined(token: type.newToken(.delimiter, ", ", node)) +
            type.newToken(.endOfScope, ")", node)
    }

    open override func tokenize(_ type: TupleType.Element, node: ASTNode) -> [Token] {
        var nameTokens = [Token]()
        if let name = type.name {
            nameTokens = type.newToken(.keyword, "val", node) +
                type.newToken(.space, " ", node) +
                type.newToken(.identifier, name, node) +
                type.newToken(.delimiter, ":", node)
        }
        return [
            nameTokens,
            tokenize(type.attributes, node: node),
            tokenize(type.type, node: node)
        ].joined(token: type.newToken(.space, " ", node))
    }

    // MARK: - Patterns


    // MARK: - Utils

    open override func tokenize(_ conditions: ConditionList, node: ASTNode) -> [Token] {
        return conditions.map { tokenize($0, node: node) }
            .joined(token: node.newToken(.delimiter, " && "))
            .prefix(with: node.newToken(.startOfScope, "("))
            .suffix(with: node.newToken(.endOfScope, ")"))
    }

    open override func tokenize(_ condition: Condition, node: ASTNode) -> [Token] {
        switch condition {
        case let .let(pattern, _):
            return tokenizeNullCheck(pattern: pattern, condition: condition, node: node)
        case let .var(pattern, _):
            return tokenizeNullCheck(pattern: pattern, condition: condition, node: node)
        default:
            return super.tokenize(condition, node: node)
        }
    }

    open override func tokenize(_ origin: ThrowsKind, node: ASTNode) -> [Token] {
        return []
    }

    open func unsupportedTokens(message: String, element: ASTTokenizable, node: ASTNode) -> [Token] {
        return [element.newToken(.comment, "//FIXME: @SwiftKotlin - \(message)", node)]
    }

    // MARK: - Private helpers

    private func tokenizeDeclarationConditions(_ conditions: ConditionList, node: ASTNode) -> [Token] {
        var newlinedDeclaration = false
        var declarationTokens = [Token]()
        for condition in conditions {
            switch condition {
            case .let, .var:
                if !newlinedDeclaration {
                    // MOP-844 ensure val declarations don't cut into comments
                    declarationTokens.append(condition.newToken(.linebreak, "\n", node))
                    newlinedDeclaration = true
                }
                declarationTokens.append(contentsOf:
                    super.tokenize(condition, node: node)
                        .replacing({ $0.value == "let" },
                                   with: [condition.newToken(.keyword, "val", node)]))
                declarationTokens.append(condition.newToken(.linebreak, "\n", node))
            default: continue
            }
        }
        return declarationTokens
    }

    private func tokenizeNullCheck(pattern: AST.Pattern, condition: Condition, node: ASTNode) -> [Token] {
        return [
            tokenize(pattern, node: node),
            [condition.newToken(.symbol, "!=", node)],
            [condition.newToken(.keyword, "null", node)],
        ].joined(token: condition.newToken(.space, " ", node))
    }


    open func tokenize(_ conditions: InvertedConditionList, node: ASTNode) -> [Token] {
        return conditions.map { tokenize($0, node: node) }
            .joined(token: node.newToken(.delimiter, " || "))
            .prefix(with: node.newToken(.startOfScope, "("))
            .suffix(with: node.newToken(.endOfScope, ")"))
    }

    private func tokenize(_ condition: InvertedCondition, node: ASTNode) -> [Token] {
        let tokens = tokenize(condition.condition, node: node)
        if case Condition.expression(let expression) = condition.condition, expression is ParenthesizedExpression {
            return tokens.prefix(with: condition.condition.newToken(.symbol, "!", node))
        } else {
            var invertedTokens = [Token]()
            var inverted = false
            var lastExpressionIndex = 0
            for token in tokens {
                if let origin = token.origin, let node = token.node {
                    if origin is SequenceExpression || origin is BinaryExpression || origin is Condition {
                        let inversionMap = [
                            "==": "!=",
                            "!=": "==",
                            ">": "<=",
                            ">=": "<",
                            "<": ">=",
                            "<=": ">",
                            "is": "!is",
                        ]
                        if let newValue = inversionMap[token.value] {
                            inverted = true
                            invertedTokens.append(origin.newToken(token.kind, newValue, node))
                            continue
                        } else if token.value == "&&" || token.value == "||" {
                            if !inverted {
                                invertedTokens.insert(origin.newToken(.symbol, "!", node), at: lastExpressionIndex)
                            }
                            inverted = false
                            invertedTokens.append(origin.newToken(token.kind, token.value == "&&" ? "||" : "&&", node))
                            lastExpressionIndex = invertedTokens.count + 1
                            continue
                        }
                    } else if origin is PrefixOperatorExpression {
                        if token.value == "!" {
                            inverted = true
                            continue
                        }
                    }
                }
                invertedTokens.append(token)
            }
            if !inverted {
                invertedTokens.insert(condition.newToken(.symbol, "!", node), at: lastExpressionIndex)
            }
            return invertedTokens
        }
    }


    private func tokenizeCompanion(_ members: [StructDeclaration.Member], node: ASTNode) -> [Token] {
        return tokenizeCompanion(members.compactMap { $0.declaration }, node: node)
    }

    private func tokenizeCompanion(_ members: [ClassDeclaration.Member], node: ASTNode) -> [Token] {
        return tokenizeCompanion(members.compactMap { $0.declaration }, node: node)
    }

    private func tokenizeCompanion(_ members: [Declaration], node: ASTNode) -> [Token] {
        let membersTokens = indent(members.map(tokenize)
            .joined(token: node.newToken(.linebreak, "\n")))

        return [
            [
                node.newToken(.keyword, "companion"),
                node.newToken(.space, " "),
                node.newToken(.keyword, "object"),
                node.newToken(.space, " "),
                node.newToken(.startOfScope, "{")
            ],
            membersTokens,
            [
                node.newToken(.endOfScope, "}")
            ]
        ].joined(token: node.newToken(.linebreak, "\n"))
    }

    private func conversionUnicodeString(_ rawText:String, node:ASTNode) -> String {
        var remainingText = rawText
        var unicodeString = ""

        while let startRange = remainingText.range(of: "u{") {
            unicodeString += remainingText[..<startRange.lowerBound] + "u"
            remainingText = String(remainingText[startRange.upperBound...])

            var scopes = 1
            var i = 1
            while i < remainingText.count && scopes > 0 {
                let index = remainingText.index(remainingText.startIndex, offsetBy: i)
                i += 1
                switch remainingText[index] {
                case "}": scopes -= 1
                default: continue
                }
            }

            unicodeString += remainingText[..<remainingText.index(remainingText.startIndex, offsetBy: i - 1)]
            remainingText = String(remainingText[remainingText.index(remainingText.startIndex, offsetBy: i)...])
        }

        unicodeString += remainingText
        return unicodeString
    }

    private func tokenizeInterpolatedString(_ rawText: String, node: ASTNode) -> [Token] {
        var remainingText = conversionUnicodeString(rawText, node: node)
        var interpolatedString = ""

        while let startRange = remainingText.range(of: "\\(") {
            interpolatedString += remainingText[..<startRange.lowerBound]
            remainingText = String(remainingText[startRange.upperBound...])

            var scopes = 1
            var i = 1
            while i < remainingText.count && scopes > 0 {
                let index = remainingText.index(remainingText.startIndex, offsetBy: i)
                i += 1
                switch remainingText[index] {
                case "(": scopes += 1
                case ")": scopes -= 1
                default: continue
                }
            }
            let expression = String(remainingText[..<remainingText.index(remainingText.startIndex, offsetBy: i - 1)])
            let computedExpression = translate(content: expression).tokens?.joinedValues().replacingOccurrences(of: "\n", with: "")
            
            let expressionResult = computedExpression ?? expression // MOP-992: Only use String formatting braces when neccessary.
            if (expressionResult.contains(".") || expressionResult.contains("(") || expressionResult.contains("?") || expressionResult.contains(":")) {
                interpolatedString += "${\(expressionResult)}"
            } else {
                interpolatedString += "$\(expressionResult)"
            }
            
            remainingText = String(remainingText[remainingText.index(remainingText.startIndex, offsetBy: i)...])
        }

        interpolatedString += remainingText
        return [node.newToken(.string, interpolatedString)]
    }

    // function used to remove default arguments from override functions, since kotlin doesn't have them
    private func removeDefaultArgsFromParameters(tokens:[Token]) -> [Token] {
        var newTokens = [Token]()
        var removing = false
        var bracket = false
        for t in tokens {
            if removing && t.kind == .startOfScope && t.value == "(" {
                bracket = true
            }
            if bracket && t.kind == .endOfScope && t.value == ")" {
                bracket = false
                removing = false
                continue
            }
            if t.kind == .symbol && (t.value.contains("=")) {
                removing = true
            }
            if t.kind == .delimiter && t.value.contains(",") {
                removing = false
            }
            if !bracket && removing && t.kind == .endOfScope && t.value == ")" {
                removing = false
            }
            if !removing {
                newTokens.append(t)
            }
        }
        return newTokens
    }
    
}

public typealias InvertedConditionList = [InvertedCondition]
public struct InvertedCondition: ASTTokenizable {
    public let condition: Condition
}

extension StringProtocol {
    var firstUppercased: String { prefix(1).uppercased() + dropFirst() }
}
