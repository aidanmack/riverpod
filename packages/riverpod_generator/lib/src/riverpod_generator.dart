import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:meta/meta.dart';
import 'package:riverpod_analyzer_utils/riverpod_analyzer_utils.dart';
// ignore: implementation_imports, safe as we are the one controlling this file
import 'package:riverpod_annotation/src/riverpod_annotation.dart';
import 'package:source_gen/source_gen.dart';

import 'models.dart';
import 'parse_generator.dart';
import 'templates/family.dart';
import 'templates/stateful_provider.dart';
import 'templates/stateless_provider.dart';

const riverpodTypeChecker = TypeChecker.fromRuntime(Riverpod);

String providerDocFor(Element element) {
  return element.documentationComment == null
      ? '/// See also [${element.name}].'
      : '${element.documentationComment}\n///\n/// Copied from [${element.name}].';
}

String _hashFn(GeneratorProviderDeclaration provider, String hashName) {
  return "String $hashName() => r'${provider.computeProviderHash()}';";
}

String _hashFnName(ProviderDeclaration provider) {
  return '_\$${provider.providerElement.name.public.lowerFirst}Hash';
}

String _hashFnIdentifier(String hashFnName) {
  return "const bool.fromEnvironment('dart.vm.product') ? "
      'null : $hashFnName';
}

const _defaultProviderNameSuffix = 'Provider';

/// May be thrown by generators during [Generator.generate].
class RiverpodInvalidGenerationSourceError
    extends InvalidGenerationSourceError {
  RiverpodInvalidGenerationSourceError(
    super.message, {
    super.todo = '',
    super.element,
    this.astNode,
  });

  final AstNode? astNode;

  // TODO overrride toString to render AST nodes.
}

@immutable
class RiverpodGenerator extends ParserGenerator<Riverpod> {
  RiverpodGenerator(Map<String, Object?> mapConfig)
      : options = BuildYamlOptions.fromMap(mapConfig);

  final BuildYamlOptions options;

  @override
  String generateForUnit(List<CompilationUnit> compilationUnits) {
    final riverpodResult = ResolvedRiverpodLibraryResult.from(compilationUnits);
    return runGenerator(riverpodResult);
  }

  String runGenerator(ResolvedRiverpodLibraryResult riverpodResult) {
    for (final error in riverpodResult.errors) {
      throw RiverpodInvalidGenerationSourceError(
        error.message,
        element: error.targetElement,
        astNode: error.targetNode,
      );
    }

    final buffer = StringBuffer();

    riverpodResult.visitChildren(_RiverpodGeneratorVisitor(buffer, options));

    // Only emit the header if we actually generated something
    if (buffer.isNotEmpty) {
      buffer.write('''
// ignore_for_file: unnecessary_raw_strings, subtype_of_sealed_class, invalid_use_of_internal_member, do_not_use_environment, prefer_const_constructors, public_member_api_docs, avoid_private_typedef_functions
''');
    }

    return buffer.toString();
  }
}

class _RiverpodGeneratorVisitor extends RecursiveRiverpodAstVisitor {
  _RiverpodGeneratorVisitor(this.buffer, this.options);

  final StringBuffer buffer;
  final BuildYamlOptions options;

  String get suffix => options.providerNameSuffix ?? _defaultProviderNameSuffix;
  String get familySuffix => options.providerFamilyNameSuffix ?? suffix;

  var _didEmitHashUtils = false;
  void maybeEmitHashUtils() {
    if (_didEmitHashUtils) return;

    _didEmitHashUtils = true;
    buffer.write('''
/// Copied from Dart SDK
class _SystemHash {
  _SystemHash._();

  static int combine(int hash, int value) {
    // ignore: parameter_assignments
    hash = 0x1fffffff & (hash + value);
    // ignore: parameter_assignments
    hash = 0x1fffffff & (hash + ((0x0007ffff & hash) << 10));
    return hash ^ (hash >> 6);
  }

  static int finish(int hash) {
    // ignore: parameter_assignments
    hash = 0x1fffffff & (hash + ((0x03ffffff & hash) << 3));
    // ignore: parameter_assignments
    hash = hash ^ (hash >> 11);
    return 0x1fffffff & (hash + ((0x00003fff & hash) << 15));
  }
}
''');
  }

  @override
  void visitStatefulProviderDeclaration(
    StatefulProviderDeclaration provider,
  ) {
    super.visitStatefulProviderDeclaration(provider);

    final parameters = provider.buildMethod.parameters?.parameters;
    if (parameters == null) return;

    final hashFunctionName = _hashFnName(provider);
    final hashFn = _hashFnIdentifier(hashFunctionName);
    buffer.write(_hashFn(provider, hashFunctionName));

    if (parameters.isEmpty) {
      final providerName = '${provider.providerElement.name.lowerFirst}$suffix';
      final notifierTypedefName = providerName.startsWith('_')
          ? '_\$${provider.providerElement.name.substring(1)}'
          : '_\$${provider.providerElement.name}';

      StatefulProviderTemplate(
        provider,
        options: options,
        notifierTypedefName: notifierTypedefName,
        hashFn: hashFn,
      ).run(buffer);
    } else {
      final providerName =
          '${provider.providerElement.name.lowerFirst}$familySuffix';
      final notifierTypedefName = providerName.startsWith('_')
          ? '_\$${provider.providerElement.name.substring(1)}'
          : '_\$${provider.providerElement.name}';

      maybeEmitHashUtils();
      FamilyTemplate.stateful(
        provider,
        options: options,
        notifierTypedefName: notifierTypedefName,
        hashFn: hashFn,
      ).run(buffer);
    }
  }

  @override
  void visitStatelessProviderDeclaration(
    StatelessProviderDeclaration provider,
  ) {
    super.visitStatelessProviderDeclaration(provider);

    final parameters = provider.node.functionExpression.parameters?.parameters;
    if (parameters == null) return;

    final hashFunctionName = _hashFnName(provider);
    final hashFn = _hashFnIdentifier(hashFunctionName);
    buffer.write(_hashFn(provider, hashFunctionName));

    final refName = '${provider.providerElement.name.titled}Ref';

    // Using >1 as functional providers always have at least one parameter: ref
    // So a provider is a "family" only if it has parameters besides the ref.
    if (parameters.length > 1) {
      maybeEmitHashUtils();
      FamilyTemplate.stateless(
        provider,
        options: options,
        refName: refName,
        hashFn: hashFn,
      ).run(buffer);
    } else {
      StatelessProviderTemplate(
        provider,
        refName: refName,
        options: options,
        hashFn: hashFn,
      ).run(buffer);
    }
  }
}
