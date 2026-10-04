import { util } from '@aws-appsync/utils';

export function request(ctx) {
  const now = util.time.nowISO8601();
  return {
    operation: 'PutItem',
    key: util.dynamodb.toMapValues({ pk: 'SOURCE', sk: util.autoId() }),
    attributeValues: util.dynamodb.toMapValues({ ...ctx.args.input, createdAt: now, updatedAt: now }),
    condition: { expression: 'attribute_not_exists(pk)' },
  };
}

export function response(ctx) {
  if (ctx.error) {
    util.error(ctx.error.message, ctx.error.type);
  }
  return { ...ctx.result, id: ctx.result.sk };
}
