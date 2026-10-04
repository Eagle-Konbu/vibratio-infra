import { util } from '@aws-appsync/utils';

export function request(ctx) {
  return {
    operation: 'DeleteItem',
    key: util.dynamodb.toMapValues({ pk: 'SOURCE', sk: ctx.args.id }),
    condition: { expression: 'attribute_exists(pk)' },
  };
}

export function response(ctx) {
  if (ctx.error) {
    util.error(ctx.error.message, ctx.error.type);
  }
  return ctx.args.id;
}
